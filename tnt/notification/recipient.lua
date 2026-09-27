--- Адресат: как запись модели становится получателем уведомления.
---
--- Род адресата объявляется один раз на модель: `notices:recipient(User,
--- { addresses = { mail = 'email' } })`. Род — имя спейса модели, адресат —
--- опознаватель записи строкой, а адрес канала — поле записи либо функция
--- от неё. Письмо без поля почты у записи не уходит: канал для этого
--- адресата пропускается, а не отказывает.
---
--- **Опознаватель — строка.** В ящике адресат лежит строкой, и строкой же
--- его ищут по опознавателю из сессии: число и строка одного и того же
--- пользователя иначе стали бы двумя адресатами. Целое число Lua годится
--- только меньше 2^53 — дальше число уже потеряло цифры, и два
--- пользователя сошлись бы в одного; большое целое приходит cdata
--- `int64_t` либо `uint64_t`, как его отдаёт модель.
---
--- Читать ящик можно и по записи, и по одному опознавателю: обработчику
--- запроса хватает опознавателя из личности, и поднимать ради страницы
--- уведомлений запись пользователя незачем.

local ffi = require('ffi')

local must = require('tnt.must')

local Module = {}

--- Поле записи с опознавателем, если о нём не сказали.
Module.DEFAULT_KEY = 'id'

--- Предел целого числа Lua, которое ещё помнит все цифры.
Module.EXACT = 2 ^ 53

--- Настройки рода адресата. Незнакомый ключ — исключение.
local OPTIONS = { key = '?not_empty', addresses = '?table' }

--- Настройки страницы ящика. Незнакомый ключ — исключение.
local PAGE = { limit = '?integer', after = '?not_empty', unread = '?boolean' }

--- Размер страницы ящика, если о нём не сказали.
Module.DEFAULT_LIMIT = 20

--- Потолок страницы ящика: столько уведомлений читатель получает за раз.
Module.MAX_LIMIT = 100

--- Уровень вины: строка того, кто позвал метод адресата.
local BLAME = 2

--- Целые cdata, которыми модель отдаёт большие ключи.
local INT64 = ffi.typeof('int64_t')
local UINT64 = ffi.typeof('uint64_t')

---@class TntNotificationRecipientKind Род адресата: записи одной модели
---@field center table Центр уведомлений
---@field type string Род: имя спейса модели
---@field key string Поле записи с опознавателем
---@field addresses table<string, string|fun(record: table): any> Адрес по каналу
local Recipient = {}
Recipient.__index = Recipient

--- Опознаватель строкой; негодный — текст отказа.
---@param value any
---@return string|nil id
---@return string|nil complaint
local function text_of(value)
    if type(value) == 'string' and value ~= '' then
        return value
    end

    if type(value) == 'number' and value % 1 == 0 and math.abs(value) < Module.EXACT then
        return ('%d'):format(value)
    end

    -- Запись cdata — цифры с приставкой LL либо ULL: срезается приставка,
    -- а не выбираются цифры, и знак остаётся как есть.
    if ffi.istype(INT64, value) or ffi.istype(UINT64, value) then
        return (tostring(value):gsub('U?LL$', ''))
    end

    return nil,
        ('— непустая строка, целое меньше 2^53 либо cdata int64_t и uint64_t, а не %s'):format(
            tostring(value)
        )
end

--- Адресат по записи либо по опознавателю.
---@param target any Запись модели либо опознаватель
---@param level integer Уровень вины
---@return TntNotificationRecipientRef
function Recipient:ref(target, level)
    local value, name = target, 'адресат'

    if type(target) == 'table' then
        value, name = target[self.key], ('адресат.%s'):format(self.key)
    end

    local id, complaint = text_of(value)

    if id == nil then
        error(('%s %s'):format(name, complaint), level + 1)
    end

    return { type = self.type, id = id }
end

--- Адрес записи в канале: поле записи либо итог функции.
---@param channel string
---@param record table
---@return any
function Recipient:address(channel, record)
    local way = self.addresses[channel]

    if type(way) == 'string' then
        return record[way]
    end

    if way ~= nil then
        return way(record)
    end

    return nil
end

--- Отправляет уведомление записи: вид по имени, данные — виду.
---
--- Отчёт — какие каналы положили уведомление на узле, какие поставили
--- в очередь и какие пропущены: у адресата нет адреса канала.
---@param record table Запись модели
---@param kind string Имя вида уведомления
---@param data table|nil Данные для видов каналов
---@return table|nil report `{ id, stored, queued, skipped }`
---@return TntStorageFailure|nil err
function Recipient:notify(record, kind, data)
    must.at(BLAME).table(record, 'адресат')

    -- Не хвостовой вызов: хвостовой убрал бы этот кадр со стека, и уровень
    -- вины в отправке показывал бы мимо строки вызывающего.
    local report, err = self.center:_send(self, record, kind, data, BLAME + 1)

    return report, err
end

--- Ящик центра; без него читать нечего — исключение.
---@param self TntNotificationRecipientKind
---@return TntNotificationInbox
local function inbox_of(self)
    local inbox = self.center.inbox

    if inbox == nil then
        error(
            'уведомления без ящика: inbox центру не дали, и читать нечего',
            BLAME + 1
        )
    end

    return inbox
end

--- Страница ящика адресата: новые первыми.
---@param target any Запись модели либо опознаватель
---@param opts { limit: integer|nil, after: string|nil, unread: boolean|nil }|nil
---@return TntNotificationPage
function Recipient:page(target, opts)
    local caller = must.at(BLAME)
    local recipient = self:ref(target, BLAME)

    caller.optional.options(opts, 'настройки страницы', PAGE)

    local given = opts or {}
    local limit = given.limit or Module.DEFAULT_LIMIT

    caller.between(limit, 'настройки страницы.limit', 1, Module.MAX_LIMIT)

    return inbox_of(self):page(recipient, { limit = limit, after = given.after, unread = given.unread })
end

--- Сколько у адресата непрочитанных.
---@param target any Запись модели либо опознаватель
---@return integer
function Recipient:unread(target)
    local recipient = self:ref(target, BLAME)

    return inbox_of(self):unread(recipient)
end

--- Помечает прочитанным одно уведомление адресата.
---
--- Чужое, прочитанное и несуществующее — `false`.
---@param target any Запись модели либо опознаватель
---@param id string Опознаватель уведомления
---@return boolean|nil marked
---@return TntStorageFailure|nil err
function Recipient:mark_read(target, id)
    local recipient = self:ref(target, BLAME)

    must.at(BLAME).not_empty(id, 'опознаватель уведомления')

    return inbox_of(self):mark_read(recipient, id)
end

--- Помечает прочитанным всё непрочитанное адресата и отдаёт, сколько.
---@param target any Запись модели либо опознаватель
---@return integer|nil marked
---@return TntStorageFailure|nil err
function Recipient:mark_all_read(target)
    local recipient = self:ref(target, BLAME)

    return inbox_of(self):mark_all_read(recipient)
end

--- Заводит род адресата.
---
--- Адрес канала — имя поля записи либо функция от записи; канал, которого
--- у центра нет, — исключение: адрес, который некуда отдать, — опечатка.
---@param center table Центр уведомлений: у него спрашиваются каналы
---@param model table Модель `tnt-model` либо таблица с полем `space`
---@param opts { key: string|nil, addresses: table|nil }|nil
---@param level integer Уровень вины: строка того, кто объявил род
---@return TntNotificationRecipientKind
function Module.new(center, model, opts, level)
    local caller = must.at(level + 1)

    caller.table(model, 'модель адресата')
    caller.not_empty(model.space, 'модель адресата.space')
    caller.optional.options(opts, 'настройки адресата', OPTIONS)

    local given = opts or {}
    local addresses = given.addresses or {}

    for channel, way in pairs(addresses) do
        if center.channels[channel] == nil then
            error(
                ('настройки адресата.addresses: канала %s у центра нет'):format(
                    tostring(channel)
                ),
                level + 1
            )
        end

        caller.kind(way, ('настройки адресата.addresses.%s'):format(channel), 'string|callable')
    end

    return setmetatable({
        center = center,
        type = model.space,
        key = given.key or Module.DEFAULT_KEY,
        addresses = addresses,
    }, Recipient)
end

return Module
