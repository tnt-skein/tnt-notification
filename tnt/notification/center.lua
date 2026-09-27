--- Центр уведомлений: виды, каналы, отправка и обработчик очереди.
---
--- Вид уведомления объявляется один раз: по каким каналам он уходит
--- (`via`) и что каждый канал из него делает — функция вида канала от
--- данных и записи адресата. Отправка идёт так:
---
---   1. виды каналов исполняются в файбере вызывающего, и каналы готовят
---      из их итога то, что уйдёт: письмо по шаблону, тело вебхука;
---   2. ящик на узле и сообщения очереди для остальных каналов пишутся
---      **одной транзакцией box** — уведомление либо легло целиком, либо
---      не легло вовсе, и повтор отправки не удвоит ни одного канала;
---   3. работник очереди доставляет сообщение каналу, а отказ канала
---      возвращает сообщение на повтор с отступом.
---
--- Внутри чужой транзакции отправка — её часть: «сохранили ответ
--- и уведомили» фиксируются вместе, а отказ отправки откатывает только
--- её собственную запись (точка сохранения), и транзакция вызывающего
--- остаётся ему.
---
--- **Канал, кроме ящика, ходит только очередью.** Очередь — таблица
--- с методом `send(body)`, чья отправка в транзакции box становится её
--- частью, как у `tnt-queue`. Канал по сети из транзакции не позвать:
--- уступка оборвала бы её, а письмо, ушедшее до отката, не вернуть.
--- Поэтому канал без очереди — исключение при объявлении вида.
---
--- Отказ — пара `nil, err` с `TntStorageFailure`; ошибка программиста —
--- исключение на строке вызывающего: незнакомый вид, канал, которого нет,
--- вид канала, который вернул не то.

local clock = require('tnt.clock')
local external = require('tnt.external')
local id = require('tnt.id')
local must = require('tnt.must')
local storage = require('tnt.storage')

local recipients = require('tnt.notification.recipient')

local failure = storage.failure

--- Бросок без места: исключение из работы отправки уходит наверх как есть,
--- со своим местом, после отката.
local raise = require('tnt.must.fail').raise

---@class TntNotificationCenterModule
---@field _set_source fun(replacement: table|nil) Подмена опознавателя и часов; ставит `external.install`
local Module = {}

--- Имя канала ящика на узле: оно же ключ вида для ящика.
Module.INBOX = 'inbox'

--- Настройки центра. Незнакомый ключ — исключение.
local OPTIONS = { inbox = '?table', channels = '?table', queue = '?table' }

--- Опознаватель и стенные часы уведомления — через внешнюю зависимость:
--- проверка сверяет их числом и строкой, а не «похоже на ULID».
local source = external.install(Module, { ulid = id.ulid, now = clock.realtime })

---@class TntNotificationChannel Канал доставки
---@field prepare fun(self: TntNotificationChannel, content: any, address: any, notice: TntNotificationNotice): any
---@field deliver fun(self: TntNotificationChannel, payload: any, notice: TntNotificationNotice): boolean|nil, any

---@class TntNotificationNotice Уведомление, как его видят каналы
---@field id string ULID уведомления: один на все каналы
---@field kind string Вид уведомления
---@field created number Стенное время отправки, секунды
---@field recipient TntNotificationRecipientRef

---@class TntNotificationKind Объявленный вид уведомления
---@field name string
---@field via string[]|fun(record: table, data: any): string[] Каналы вида
---@field views table<string, fun(data: any, record: table): any> Вид канала по имени

---@class TntNotificationCenter Центр уведомлений
---@field inbox TntNotificationInbox|nil Ящик на узле
---@field channels table<string, TntNotificationChannel> Каналы по имени
---@field queue table|nil Очередь по договору: у неё спрашивается `send`
---@field kinds table<string, TntNotificationKind> Виды по имени
local Center = {}
Center.__index = Center

--- Каналы, которые знает центр, по алфавиту — для отказов.
---@param self TntNotificationCenter
---@return string
local function known_channels(self)
    local names = {}

    if self.inbox ~= nil then
        table.insert(names, Module.INBOX)
    end

    for name in pairs(self.channels) do
        table.insert(names, name)
    end

    table.sort(names)

    return table.concat(names, ', ')
end

--- Проверяет, что канал есть у центра и может уйти.
---
--- Ящику нужен ящик, остальным — очередь: без неё канал по сети пришлось
--- бы звать из транзакции.
---@param self TntNotificationCenter
---@param name any
---@param where string Чей это канал — для отказа
---@param level integer Уровень вины
local function reachable(self, name, where, level)
    local present = (name == Module.INBOX and self.inbox ~= nil) or self.channels[name] ~= nil

    if not present then
        error(
            ('%s: канала %s у центра нет; есть %s'):format(
                where,
                tostring(name),
                known_channels(self)
            ),
            level + 1
        )
    end

    if name ~= Module.INBOX and self.queue == nil then
        error(
            ('%s: канал %s ходит очередью, а queue центру не дали'):format(where, name),
            level + 1
        )
    end
end

--- Проверяет список каналов вида: каждый есть у центра и у вида есть его вид.
---@param self TntNotificationCenter
---@param kind TntNotificationKind
---@param via any
---@param level integer Уровень вины
local function check_via(self, kind, via, level)
    local where = ('вид уведомления %s'):format(kind.name)

    must.at(level + 1).array(via, where .. '.via')

    for _, name in ipairs(via) do
        reachable(self, name, where, level + 1)

        if kind.views[name] == nil then
            error(('%s: канал %s в via, а вида для него нет'):format(where, name), level + 1)
        end
    end
end

--- Объявляет вид уведомления.
---
--- `via` — список каналов либо функция `(record, data) → список`: так
--- вид слушается настроек адресата («письма не присылать»). Остальные
--- ключи — виды каналов: `inbox = function(data, record) … end` и соседи.
--- Вид канала, которого у центра нет, — исключение: это опечатка, и
--- молча пропущенный вид означал бы канал, который не уходит никогда.
---@param name string Имя вида
---@param spec table `{ via = …, <канал> = function(data, record) … end }`
---@return TntNotificationKind
function Center:declare(name, spec)
    local caller = must.at(2)

    caller.not_empty(name, 'имя вида уведомления')
    caller.table(spec, ('вид уведомления %s'):format(name))

    if self.kinds[name] ~= nil then
        error(('вид уведомления %s уже объявлен'):format(name), 2)
    end

    local kind = { name = name, via = spec.via, views = {} }

    for key, view in pairs(spec) do
        if key ~= 'via' then
            reachable(self, key, ('вид уведомления %s'):format(name), 2)
            caller.callable(view, ('вид уведомления %s.%s'):format(name, key))
            kind.views[key] = view
        end
    end

    caller.kind(spec.via, ('вид уведомления %s.via'):format(name), 'array|callable')

    if type(spec.via) == 'table' then
        check_via(self, kind, spec.via, 2)
    end

    self.kinds[name] = kind

    return kind
end

--- Заводит род адресата: записи модели, которым уходят уведомления.
---@param model table Модель `tnt-model` либо таблица с полем `space`
---@param opts { key: string|nil, addresses: table|nil }|nil
---@return TntNotificationRecipientKind
function Center:recipient(model, opts)
    local kind = recipients.new(self, model, opts, 2)

    return kind
end

--- Пишет уведомление на узел одной транзакцией: ящик и сообщения очереди.
---
--- Внутри чужой транзакции — точка сохранения: отказ откатывает только
--- своё. Исключение из работы — после отката и как есть.
---@param work fun(): boolean|nil, any
---@return boolean|nil done
---@return TntStorageFailure|nil err
local function atomic(work)
    local inside = box.is_in_txn()
    local point

    if inside then
        point = box.savepoint()
    else
        box.begin()
    end

    local ok, done, err = pcall(work)

    if ok and done then
        if inside then
            return true
        end

        local committed, why = pcall(box.commit)

        if committed then
            return true
        end

        return nil,
            failure.new(
                failure.CONFLICT,
                'уведомление не легло: ' .. failure.text(why),
                { sent = false }
            )
    end

    if inside then
        box.rollback_to_savepoint(point --[[@as box.savepoint]])
    else
        box.rollback()
    end

    if not ok then
        raise(done)
    end

    return nil, err
end

--- Пишет спланированное: ящик и сообщения очереди.
---@param self TntNotificationCenter
---@param notice TntNotificationNotice
---@param plan { stored: any, queued: { channel: string, payload: any }[] }
---@return boolean|nil done
---@return TntStorageFailure|nil err
local function write(self, notice, plan)
    -- Ящик и очередь здесь есть всегда: канал без них отвергнут при
    -- объявлении вида либо при разборе `via`.
    local inbox = self.inbox --[[@as TntNotificationInbox]]
    local queue = self.queue --[[@as table]]

    if plan.stored ~= nil then
        local stored, err = inbox:put(notice, plan.stored)

        if not stored then
            return nil, err
        end
    end

    for _, message in ipairs(plan.queued) do
        local sent, err = queue:send({
            id = notice.id,
            kind = notice.kind,
            created = notice.created,
            recipient = notice.recipient,
            channel = message.channel,
            payload = message.payload,
        })

        if sent == nil then
            return nil, err
        end
    end

    return true
end

--- Отправляет уведомление адресату; зовёт его `recipient:notify`.
---@param kind_of TntNotificationRecipientKind Род адресата
---@param record table Запись модели
---@param name string Имя вида
---@param data any Данные для видов каналов
---@param level integer Уровень вины: строка того, кто позвал `notify`
---@return table|nil report
---@return TntStorageFailure|nil err
function Center:_send(kind_of, record, name, data, level)
    local kind = self.kinds[name]

    if kind == nil then
        local names = {}

        for known in pairs(self.kinds) do
            table.insert(names, known)
        end

        table.sort(names)

        error(
            ('вида уведомления %s нет; есть %s'):format(tostring(name), table.concat(names, ', ')),
            level
        )
    end

    must.at(level).optional.table(data, ('данные уведомления %s'):format(name))

    local notice = {
        id = source().ulid(),
        kind = name,
        created = source().now(),
        recipient = kind_of:ref(record, level),
    }

    local via = kind.via

    if type(via) ~= 'table' then
        via = via(record, data)
        check_via(self, kind, via, level)
    end

    local report = { id = notice.id, stored = {}, queued = {}, skipped = {} }
    local plan = { queued = {} }

    for _, channel in ipairs(via) do
        local content = kind.views[channel](data, record)

        if channel == Module.INBOX then
            must.at(level).table(content, ('вид уведомления %s.inbox вернул'):format(name))
            plan.stored = content
            table.insert(report.stored, channel)
        else
            local address = kind_of:address(channel, record)
            local payload = self.channels[channel]:prepare(content, address, notice)

            if payload == nil then
                table.insert(report.skipped, channel)
            else
                table.insert(plan.queued, { channel = channel, payload = payload })
                table.insert(report.queued, channel)
            end
        end
    end

    local done, err = atomic(function()
        return write(self, notice, plan)
    end)

    if not done then
        return nil, err
    end

    return report
end

--- Отказ о негодном сообщении: зарыть сразу, повтор ничего не даст.
---@param text string
---@return TntStorageFailure
local function rejected(text)
    return failure.new(failure.REJECTED, 'уведомления: ' .. text, { retriable = false })
end

--- Доставляет сообщение очереди каналу: значение подтверждает, пара
--- `nil, err` возвращает сообщение работнику.
---
--- Негодное сообщение и канал, которого у центра больше нет, зарываются
--- сразу: вход из очереди недоверенный, а канал, убранный из настроек,
--- не вернётся от повтора — его зарытые сообщения ждут решения человека.
---@param message table Конверт по договору очереди
---@return boolean|nil delivered
---@return TntStorageFailure|nil err
function Center:handle(message)
    local body = type(message) == 'table' and message.body or nil

    if type(body) ~= 'table' or type(body.channel) ~= 'string' or type(body.id) ~= 'string' then
        return nil,
            rejected('в сообщении нет канала и опознавателя уведомления')
    end

    local channel = self.channels[body.channel]

    if channel == nil then
        return nil,
            rejected(('канала %s у центра нет; есть %s'):format(body.channel, known_channels(self)))
    end

    return channel:deliver(body.payload, {
        id = body.id,
        kind = body.kind,
        created = body.created,
        recipient = body.recipient,
    })
end

--- Обработчик для `queue:consume`.
---@return fun(message: table): boolean|nil, TntStorageFailure|nil
function Center:handler()
    return function(message)
        return self:handle(message)
    end
end

--- Заводит центр уведомлений.
---
--- Каналы — таблица «имя → канал»: у канала есть `prepare` и `deliver`.
--- Имя `inbox` занято ящиком: он приходит своей настройкой.
---@param opts { inbox: TntNotificationInbox|nil, channels: table|nil, queue: table|nil }|nil
---@return TntNotificationCenter
function Module.new(opts)
    local caller = must.at(2)

    caller.optional.options(opts, 'настройки уведомлений', OPTIONS)

    local given = opts or {}
    local channels = given.channels or {}

    if channels[Module.INBOX] ~= nil then
        local taken =
            'настройки уведомлений.channels: имя inbox занято ящиком — он приходит настройкой inbox'

        error(taken, 2)
    end

    for name, channel in pairs(channels) do
        local where = ('настройки уведомлений.channels.%s'):format(name)

        caller.table(channel, where)
        caller.callable(channel.prepare, where .. '.prepare')
        caller.callable(channel.deliver, where .. '.deliver')
    end

    if given.queue ~= nil then
        caller.callable(given.queue.send, 'настройки уведомлений.queue.send')
    end

    return setmetatable({ inbox = given.inbox, channels = channels, queue = given.queue, kinds = {} }, Center)
end

return Module
