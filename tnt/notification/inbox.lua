--- Ящик уведомлений на узле: спейс с признаком «прочитано».
---
--- Кортеж — `{ id, recipient_type, recipient_id, kind, data, created,
--- read, read_at }`. Опознаватель — ULID уведомления: время в старших
--- знаках, поэтому порядок по нему — порядок по времени, и страница
--- «новые сверху» — обратный обход без отдельного поля времени в индексе.
---
--- Индексов три: первичный по опознавателю, `recipient` — все уведомления
--- адресата, `unread` — только непрочитанные. Признак «прочитано» стоит
--- в `unread` третьей частью: выборка непрочитанных — ключ
--- `{ род, адресат, false }`, и счёт по нему не обходит прочитанное.
---
--- **Запись внутри чужой транзакции — её часть.** Своей транзакции ящик
--- тогда не открывает: «сохранили ответ и уведомили» одной транзакцией —
--- то, ради чего ящик и держат рядом с данными. Уступка у пометки всего
--- прочитанного — только вне транзакции: внутри уступка оборвала бы саму
--- транзакцию memtx, и предел такой работы — срез файбера.
---
--- Отказ `box` — пара `nil, err` с `TntStorageFailure`: на узле только для
--- чтения — `unreachable`, иначе — `broken`. Спейса нет — исключение
--- без места: это не отказ узла, а пропущенный шаг миграции.

local fiber = require('fiber')

local clock = require('tnt.clock')
local external = require('tnt.external')
local must = require('tnt.must')
local storage = require('tnt.storage')

local failure = storage.failure

--- Бросок без места: пропущенный шаг миграции чинят не в строке вызова.
local fail = require('tnt.must.fail').raise

---@class TntNotificationInboxModule
---@field _set_source fun(replacement: table|nil) Подмена часов — для проверок; ставит её `external.install`
local Module = {}

--- Спейс ящика, если о нём не сказали.
Module.DEFAULT_SPACE = 'notifications'

--- Индекс всех уведомлений адресата.
Module.BY_RECIPIENT = 'recipient'

--- Индекс непрочитанных уведомлений адресата.
Module.UNREAD = 'unread'

--- Сколько непрочитанных пометка всего прочитанного берёт за один кусок.
---
--- Кусок — одна транзакция и одна запись в WAL: пятьсот замен укладываются
--- в миллисекунды, а весь ящик одним куском на десятках тысяч записей
--- упёрся бы в срез файбера.
Module.CHUNK = 500

--- Номера полей кортежа: по ним собирается запись для вызывающего.
local ID, TYPE, RECIPIENT, KIND, DATA, CREATED, READ, READ_AT = 1, 2, 3, 4, 5, 6, 7, 8

--- Формат спейса ящика.
---
--- Тип данных — `any`, а не `map`: пустая таблица уезжает в msgpack пустым
--- списком, и `map` отверг бы уведомление без полей.
local FORMAT = {
    { name = 'id', type = 'string' },
    { name = 'recipient_type', type = 'string' },
    { name = 'recipient_id', type = 'string' },
    { name = 'kind', type = 'string' },
    { name = 'data', type = 'any' },
    { name = 'created', type = 'number' },
    { name = 'read', type = 'boolean' },
    { name = 'read_at', type = 'number', is_nullable = true },
}

--- Настройки ящика. Незнакомый ключ — исключение.
local OPTIONS = { space = '?not_empty' }

--- Стенные часы отметок — через внешнюю зависимость: проверка сверяет
--- отметку прочтения числом, а не «где-то между».
local source = external.install(Module, { now = clock.realtime })

---@class TntNotificationRecipientRef Адресат уведомления в ящике
---@field type string Род адресата: имя спейса модели
---@field id string Опознаватель записи строкой

---@class TntNotificationItem Уведомление из ящика
---@field id string ULID уведомления
---@field kind string Вид уведомления
---@field data any Что положил вид для ящика
---@field created number Стенное время отправки, секунды
---@field read boolean Прочитано ли
---@field read_at number|nil Когда прочитано

---@class TntNotificationPage Страница ящика
---@field items TntNotificationItem[] Уведомления, новые первыми
---@field next string|nil Курсор следующей страницы; пусто — страница последняя

---@class TntNotificationInbox Ящик уведомлений на узле
---@field name string Имя спейса
local Inbox = {}
Inbox.__index = Inbox

--- Имя спейса из настроек.
---@param opts { space: string|nil }|nil
---@param level integer Уровень вины: строка того, кто позвал функцию фасада
---@return string
local function space_name(opts, level)
    must.at(level).optional.options(opts, 'настройки ящика', OPTIONS)

    return (opts or {}).space or Module.DEFAULT_SPACE
end

--- Шаг миграции: спейс ящика и его индексы.
---
--- Повторно безопасен: спейс и индексы, которые уже есть, не трогаются, а
--- недостающие заводятся — шаг, сорвавшийся посередине, доделывается
--- повтором.
---@param opts { space: string|nil }|nil
---@return fun(box: table)
function Module.migration(opts)
    local name = space_name(opts, 3)

    return function(box)
        local space = box.schema.space.create(name, { format = FORMAT, if_not_exists = true })

        space:create_index('primary', { parts = { 'id' }, if_not_exists = true })
        space:create_index(Module.BY_RECIPIENT, {
            parts = { 'recipient_type', 'recipient_id', 'id' },
            if_not_exists = true,
        })
        space:create_index(Module.UNREAD, {
            parts = { 'recipient_type', 'recipient_id', 'read', 'id' },
            if_not_exists = true,
        })
    end
end

--- Спейс ящика; нет его — исключение о пропущенном шаге миграции.
---@param self TntNotificationInbox
---@return table
local function space_of(self)
    local space = box.space[self.name]

    if space == nil then
        fail(
            ('ящик уведомлений: спейса %s нет — нужен шаг миграции notification.migration()'):format(
                self.name
            )
        )
    end

    return space
end

--- Отказ box при записи.
---
--- Узел для чтения — `unreachable`: запись дойдёт, когда узел начнёт
--- писать, и повтор тут уместен. Прочее — `broken`, и тоже повторяемый:
--- транзакция ящика откачена, и повтор ничего не удвоит.
---@param err any Что бросил box
---@return TntStorageFailure
local function refused(err)
    if box.info.ro then
        return failure.new(
            failure.UNREACHABLE,
            'ящик уведомлений не принимает: узел только для чтения'
        )
    end

    return failure.new(
        failure.BROKEN,
        'ящик уведомлений: ' .. failure.text(err),
        { sent = false, retriable = true }
    )
end

--- Уведомление из кортежа.
---@param tuple table
---@return TntNotificationItem
local function item_of(tuple)
    return {
        id = tuple[ID],
        kind = tuple[KIND],
        data = tuple[DATA],
        created = tuple[CREATED],
        read = tuple[READ],
        read_at = tuple[READ_AT],
    }
end

--- Кладёт уведомление в ящик.
---@param notice { id: string, kind: string, created: number, recipient: TntNotificationRecipientRef }
---@param data any Что положил вид для ящика
---@return boolean|nil stored
---@return TntStorageFailure|nil err
function Inbox:put(notice, data)
    local space = space_of(self)
    local row = { notice.id, notice.recipient.type, notice.recipient.id, notice.kind, data, notice.created, false }
    local ok, err = pcall(space.insert, space, row)

    if not ok then
        return nil, refused(err)
    end

    return true
end

--- Страница уведомлений адресата: новые первыми.
---
--- Курсор — опознаватель последнего уведомления прежней страницы:
--- продолжение — обратный обход строго меньше него. Обход идёт итератором
--- не дальше `limit + 1` кортежей: лишний показывает, есть ли следующая
--- страница, и на чужом адресате, куда уходит обратный обход, он кончается.
---@param recipient TntNotificationRecipientRef
---@param opts { limit: integer, after: string|nil, unread: boolean|nil }
---@return TntNotificationPage
function Inbox:page(recipient, opts)
    local space = space_of(self)
    local index = space.index[Module.BY_RECIPIENT]
    local key = { recipient.type, recipient.id }

    if opts.unread then
        index = space.index[Module.UNREAD]
        table.insert(key, false)
    end

    local iterator = 'REQ'

    if opts.after ~= nil then
        table.insert(key, opts.after)
        iterator = 'LT'
    end

    ---@type TntNotificationItem[]
    local items = {}

    for _, tuple in index:pairs(key, { iterator = iterator }) do
        if tuple[TYPE] ~= recipient.type or tuple[RECIPIENT] ~= recipient.id then
            break
        end

        if #items == opts.limit then
            return { items = items, next = items[#items].id }
        end

        table.insert(items, item_of(tuple))
    end

    return { items = items }
end

--- Сколько у адресата непрочитанных.
---@param recipient TntNotificationRecipientRef
---@return integer
function Inbox:unread(recipient)
    return space_of(self).index[Module.UNREAD]:count({ recipient.type, recipient.id, false })
end

--- Помечает прочитанным одно уведомление адресата.
---
--- Чужое уведомление и уведомление, которого нет, — `false`, а не отказ:
--- по опознавателю из адресной строки нельзя ни пометить чужое, ни узнать,
--- что оно есть. Уже прочитанное — тоже `false`: отметка прочтения
--- остаётся первой.
---@param recipient TntNotificationRecipientRef
---@param id string
---@return boolean|nil marked
---@return TntStorageFailure|nil err
function Inbox:mark_read(recipient, id)
    local space = space_of(self)
    local tuple = space:get(id)

    if tuple == nil or tuple[TYPE] ~= recipient.type or tuple[RECIPIENT] ~= recipient.id or tuple[READ] then
        return false
    end

    local ok, err = pcall(space.update, space, id, { { '=', READ, true }, { '=', READ_AT, source().now() } })

    if not ok then
        return nil, refused(err)
    end

    return true
end

--- Помечает кусок непрочитанных одной транзакцией.
---@param space table
---@param tuples table[]
---@param now number
local function mark_chunk(space, tuples, now)
    for _, tuple in ipairs(tuples) do
        space:update(tuple[ID], { { '=', READ, true }, { '=', READ_AT, now } })
    end
end

--- Помечает прочитанным всё непрочитанное адресата и отдаёт, сколько.
---
--- Кусками по `CHUNK`: помеченное уходит из ключа непрочитанных, и каждый
--- следующий кусок — снова первые `CHUNK` по тому же ключу, без курсора.
--- Вне транзакции кусок — своя транзакция, а между кусками уступка;
--- внутри чужой транзакции куски — её часть и идут без уступок.
---@param recipient TntNotificationRecipientRef
---@return integer|nil marked
---@return TntStorageFailure|nil err
function Inbox:mark_all_read(recipient)
    local space = space_of(self)
    local index = space.index[Module.UNREAD]
    local key = { recipient.type, recipient.id, false }
    local inside = box.is_in_txn()
    local now = source().now()
    local marked = 0

    while true do
        local tuples = index:select(key, { limit = Module.CHUNK })

        if #tuples == 0 then
            return marked
        end

        local ok, err

        if inside then
            ok, err = pcall(mark_chunk, space, tuples, now)
        else
            ok, err = pcall(box.atomic, mark_chunk, space, tuples, now)
        end

        if not ok then
            return nil, refused(err)
        end

        marked = marked + #tuples

        if not inside then
            fiber.yield()
        end
    end
end

--- Заводит ящик над спейсом.
---
--- Спейс спрашивается при каждом обращении, а не здесь: ящик объявляют
--- при загрузке модуля приложения, а шаг миграции идёт позже, при подъёме
--- узла.
---@param opts { space: string|nil }|nil
---@return TntNotificationInbox
function Module.new(opts)
    return setmetatable({ name = space_name(opts, 3) }, Inbox)
end

return Module
