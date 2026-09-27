--- Центр уведомлений в процессе: настройки, объявление видов, род
--- адресата, отказы отправки до записи и обработчик очереди.
---
--- Запись ящика и очереди одной транзакцией идёт на узле
--- (`node_test.lua`); здесь — всё, что решается до `box`.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local notification = helper.notification
local failure = helper.failure

local g = t.group('tnt.notification.center')

--- Канал-двойник: помнит доставленное и отвечает заготовленным.
---@param answer table|nil `{ true }` либо `{ nil, err }`
---@return table channel
---@return table delivered
local function channel(answer)
    local delivered = {}
    local scripted = answer or { true }

    return {
        prepare = function(_, content, address)
            if address == nil then
                return nil
            end

            return { content = content, address = address }
        end,
        deliver = function(_, payload, notice)
            table.insert(delivered, { payload = payload, notice = notice })

            return scripted[1], scripted[2]
        end,
    },
        delivered
end

--- Центр с ящиком-двойником, каналом push и очередью-двойником.
---@return table center
local function center()
    local push = channel()

    return notification.new({ inbox = {}, channels = { push = push }, queue = helper.queue() })
end

g.test_the_facade_exposes_its_parts = function()
    t.assert_equals(notification.center, helper.notification.center)
    t.assert_is(notification.new, notification.center.new)
    t.assert_equals(notification.center.INBOX, 'inbox')
end

g.test_settings_are_checked_on_the_callers_line = function()
    local wrong = helper.wrong

    helper.assert_blamed({
        {
            function()
                notification.new({ chanels = {} })
            end,
            'настройки уведомлений: ключа «chanels» нет, есть channels, inbox, queue',
        },
        {
            function()
                notification.new({ channels = { inbox = channel() } })
            end,
            'настройки уведомлений.channels: имя inbox занято ящиком — он приходит настройкой inbox',
        },
        {
            function()
                notification.new({ channels = { push = wrong(5) } })
            end,
            'настройки уведомлений.channels.push — таблица, а не число',
        },
        {
            function()
                notification.new({ channels = { push = { deliver = print } } })
            end,
            'настройки уведомлений.channels.push.prepare — функция или вызываемая таблица, а не nil',
        },
        {
            function()
                notification.new({ channels = { push = { prepare = print } } })
            end,
            'настройки уведомлений.channels.push.deliver — функция или вызываемая таблица, а не nil',
        },
        {
            function()
                notification.new({ queue = {} })
            end,
            'настройки уведомлений.queue.send — функция или вызываемая таблица, а не nil',
        },
    })
end

g.test_a_center_without_settings_has_nothing = function()
    local bare = notification.new()

    t.assert_equals(bare.channels, {})
    t.assert_equals(bare.kinds, {})
    t.assert_equals(bare.inbox, nil)
    t.assert_equals(bare.queue, nil)
end

g.test_a_declaration_is_kept_by_name = function()
    local notices = center()
    local inbox_view = function()
        return {}
    end
    local via = function()
        return { 'inbox' }
    end

    local kind = notices:declare('replied', { via = { 'inbox', 'push' }, inbox = inbox_view, push = inbox_view })
    local chosen = notices:declare('chosen', { via = via, inbox = inbox_view })

    t.assert_is(notices.kinds.replied, kind)
    t.assert_equals(kind.name, 'replied')
    t.assert_equals(kind.via, { 'inbox', 'push' })
    t.assert_equals(kind.views, { inbox = inbox_view, push = inbox_view })
    t.assert_is(chosen.via, via)
end

g.test_a_bad_declaration_is_an_exception_on_the_callers_line = function()
    local notices = center()
    local view = function() end
    local wrong = helper.wrong

    notices:declare('replied', { via = { 'inbox' }, inbox = view })

    helper.assert_blamed({
        {
            function()
                notices:declare('', { via = {} })
            end,
            'имя вида уведомления — непустая строка, а не пустая',
        },
        {
            function()
                notices:declare('greeted', wrong(nil))
            end,
            'вид уведомления greeted — таблица, а не nil',
        },
        {
            function()
                notices:declare('replied', { via = { 'inbox' }, inbox = view })
            end,
            'вид уведомления replied уже объявлен',
        },
        {
            function()
                notices:declare('greeted', { via = { 'inbox' }, inbox = view, mail = view })
            end,
            'вид уведомления greeted: канала mail у центра нет; есть inbox, push',
        },
        {
            function()
                notices:declare('greeted', { via = { 'inbox' }, inbox = 'текст' })
            end,
            'вид уведомления greeted.inbox — функция или вызываемая таблица, а не строка',
        },
        {
            function()
                notices:declare('greeted', { inbox = view })
            end,
            'вид уведомления greeted.via — массив или функция или вызываемая таблица, а не nil',
        },
        {
            function()
                notices:declare('greeted', { via = { 'push' }, inbox = view })
            end,
            'вид уведомления greeted: канал push в via, а вида для него нет',
        },
        {
            function()
                notices:declare('greeted', { via = { 'sms' }, inbox = view })
            end,
            'вид уведомления greeted: канала sms у центра нет; есть inbox, push',
        },
        {
            function()
                notices:declare('greeted', { via = { inbox = true }, inbox = view })
            end,
            'вид уведомления greeted.via — массив или функция или вызываемая таблица, а не таблица',
        },
    })

    t.assert_equals(notices.kinds.greeted, nil, 'негодное объявление не остаётся')
end

g.test_a_channel_without_a_queue_or_an_inbox_is_refused = function()
    local view = function() end
    local lonely = notification.new({ channels = { push = channel() } })

    helper.assert_blamed({
        {
            function()
                lonely:declare('greeted', { via = { 'push' }, push = view })
            end,
            'вид уведомления greeted: канал push ходит очередью, а queue центру не дали',
        },
        {
            function()
                lonely:declare('greeted', { via = { 'inbox' }, inbox = view })
            end,
            'вид уведомления greeted: канала inbox у центра нет; есть push',
        },
    })
end

g.test_a_recipient_kind_is_made_by_the_center = function()
    local notices = center()
    local users = notices:recipient({ space = 'users' }, { key = 'login', addresses = { push = 'device' } })

    t.assert_is(users.center, notices)
    t.assert_equals(users.type, 'users')
    t.assert_equals(users.key, 'login')
    t.assert_equals(users.addresses, { push = 'device' })
end

g.test_sending_checks_its_arguments_on_the_callers_line = function()
    local notices = center()
    local users = notices:recipient({ space = 'users' })
    local wrong = helper.wrong

    notices:declare('replied', { via = { 'inbox' }, inbox = function() end })
    notices:declare('chosen', {
        via = function(_, data)
            return data.via
        end,
        inbox = function() end,
    })

    helper.assert_blamed({
        {
            function()
                users:notify(wrong(7), 'replied')
            end,
            'адресат — таблица, а не число',
        },
        {
            function()
                users:notify({ id = 7 }, 'greeted')
            end,
            'вида уведомления greeted нет; есть chosen, replied',
        },
        {
            function()
                users:notify({ id = 7 }, 'replied', wrong('данные'))
            end,
            'данные уведомления replied — таблица, а не строка',
        },
        {
            function()
                users:notify({ id = 0.5 }, 'replied')
            end,
            'адресат.id — непустая строка, целое меньше 2^53 либо cdata int64_t и uint64_t, а не 0.5',
        },
        {
            function()
                users:notify({ id = 7 }, 'chosen', { via = { 'push' } })
            end,
            'вид уведомления chosen: канал push в via, а вида для него нет',
        },
        {
            function()
                users:notify({ id = 7 }, 'chosen', { via = 'inbox' })
            end,
            'вид уведомления chosen.via — массив, а не строка',
        },
    })
end

g.test_a_view_of_the_inbox_returns_a_table = function()
    local notices = center()
    local users = notices:recipient({ space = 'users' })

    notices:declare('replied', {
        via = { 'inbox' },
        inbox = function()
            return 'текст'
        end,
    })

    helper.assert_blamed({
        {
            function()
                users:notify({ id = 7 }, 'replied')
            end,
            'вид уведомления replied.inbox вернул — таблица, а не строка',
        },
    })
end

g.test_the_handler_delivers_to_the_named_channel = function()
    local push, delivered = channel()
    local notices = notification.new({ channels = { push = push }, queue = helper.queue() })
    local handler = notices:handler()

    local done, err = handler({
        body = {
            id = '01K5Z0000000000000000000AB',
            kind = 'replied',
            created = 17,
            recipient = { type = 'users', id = '7' },
            channel = 'push',
            payload = { address = 'device-1' },
        },
    })

    t.assert_equals({ done, err }, { true, nil })
    t.assert_equals(delivered, {
        {
            payload = { address = 'device-1' },
            notice = {
                id = '01K5Z0000000000000000000AB',
                kind = 'replied',
                created = 17,
                recipient = { type = 'users', id = '7' },
            },
        },
    })
end

g.test_a_refusal_of_the_channel_goes_back_to_the_queue = function()
    local refusal = failure.new(failure.BUSY, 'занято')
    local push = channel({ nil, refusal })
    local notices = notification.new({ channels = { push = push }, queue = helper.queue() })

    local done, err = notices:handle({ body = { id = 'n-1', channel = 'push' } })

    t.assert_equals(done, nil)
    t.assert_is(err, refusal)
end

g.test_a_bad_message_is_buried_at_once = function()
    local notices = notification.new({ inbox = {}, channels = { push = channel() }, queue = helper.queue() })
    local cases = {
        {
            'не таблица',
            'в сообщении нет канала и опознавателя уведомления',
        },
        {
            { body = 'тело' },
            'в сообщении нет канала и опознавателя уведомления',
        },
        {
            { body = { id = 'n-1' } },
            'в сообщении нет канала и опознавателя уведомления',
        },
        {
            { body = { channel = 'push' } },
            'в сообщении нет канала и опознавателя уведомления',
        },
        { { body = { id = 'n-1', channel = 'sms' } }, 'канала sms у центра нет; есть inbox, push' },
    }

    for _, case in ipairs(cases) do
        local done, err = notices:handle(case[1])

        t.assert_equals(done, nil)
        t.assert_equals(err.kind, failure.REJECTED)
        t.assert_equals(err.retriable, false)
        t.assert_equals(tostring(err), 'уведомления: ' .. case[2])
    end
end
