--- Адресат в процессе: опознаватель строкой, адрес канала, чтение ящика
--- и отказы аргументов.
---
--- Ящик здесь — двойник: что он делает с адресатом, проверяет узел
--- (`node_test.lua`); здесь — что адресат ему отдаёт.

local ffi = require('ffi')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local notification = helper.notification
local recipient = notification.recipient

local g = t.group('tnt.notification.recipient')

--- Ящик-двойник: помнит обращения и отвечает заготовленным.
---@return table inbox
---@return table calls
local function inbox()
    local calls = {}

    local function acting(method, answer)
        return function(_, ref, argument)
            table.insert(calls, { method = method, ref = ref, argument = argument })

            return answer
        end
    end

    return {
        page = acting('page', { items = {} }),
        unread = acting('unread', 3),
        mark_read = acting('mark_read', true),
        mark_all_read = acting('mark_all_read', 4),
    },
        calls
end

--- Род адресата над центром с ящиком-двойником и каналом push.
---@param opts table|nil
---@return table users
---@return table calls
local function users_of(opts)
    local box_double, calls = inbox()
    local push = { prepare = function() end, deliver = function() end }
    local notices = notification.new({ inbox = box_double, channels = { push = push }, queue = helper.queue() })

    return notices:recipient({ space = 'users' }, opts), calls
end

g.test_the_limits_are_named = function()
    t.assert_equals(recipient.DEFAULT_KEY, 'id')
    t.assert_equals(recipient.DEFAULT_LIMIT, 20)
    t.assert_equals(recipient.MAX_LIMIT, 100)
    t.assert_equals(recipient.EXACT, 9007199254740992)
end

g.test_an_identifier_becomes_a_string = function()
    local users = users_of()
    local cases = {
        { { id = 'u-7' }, 'u-7' },
        { { id = 7 }, '7' },
        { { id = -7 }, '-7' },
        { { id = 9007199254740991 }, '9007199254740991' },
        { { id = -9007199254740991 }, '-9007199254740991' },
        { { id = ffi.new('uint64_t', 18446744073709551615ULL) }, '18446744073709551615' },
        { { id = ffi.new('int64_t', -9223372036854775807LL) }, '-9223372036854775807' },
        { 'u-8', 'u-8' },
        { 8, '8' },
    }

    for _, case in ipairs(cases) do
        t.assert_equals(users:ref(case[1], 1), { type = 'users', id = case[2] })
    end
end

g.test_the_key_field_is_a_setting = function()
    local users = users_of({ key = 'login' })

    t.assert_equals(users:ref({ id = 7, login = 'maria' }, 1), { type = 'users', id = 'maria' })
end

g.test_a_bad_identifier_is_an_exception_on_the_callers_line = function()
    local users = users_of()
    local tail =
        '— непустая строка, целое меньше 2^53 либо cdata int64_t и uint64_t, а не '

    helper.assert_blamed({
        {
            function()
                users:unread({ id = '' })
            end,
            'адресат.id ' .. tail,
        },
        {
            function()
                users:unread({ id = 9007199254740992 })
            end,
            'адресат.id ' .. tail .. '9.007199254741e+15',
        },
        {
            function()
                users:unread({ id = -9007199254740992 })
            end,
            'адресат.id ' .. tail .. '-9.007199254741e+15',
        },
        {
            function()
                users:unread(1.5)
            end,
            'адресат ' .. tail .. '1.5',
        },
        {
            function()
                users:unread(0 / 0)
            end,
            'адресат ' .. tail .. 'nan',
        },
        {
            function()
                users:unread(true)
            end,
            'адресат ' .. tail .. 'true',
        },
        {
            function()
                users:unread({})
            end,
            'адресат.id ' .. tail .. 'nil',
        },
    })
end

g.test_the_address_is_a_field_or_a_function = function()
    local users = users_of({
        addresses = {
            push = 'device',
        },
    })
    local computed = users_of({
        addresses = {
            push = function(record)
                return 'device-' .. record.id
            end,
        },
    })

    t.assert_equals(users:address('push', { device = 'd-1' }), 'd-1')
    t.assert_equals(computed:address('push', { id = 7 }), 'device-7')
    t.assert_equals(users:address('mail', { device = 'd-1' }), nil)
end

g.test_a_recipient_kind_checks_its_settings_on_the_callers_line = function()
    local push = { prepare = function() end, deliver = function() end }
    local notices = notification.new({ channels = { push = push }, queue = helper.queue() })
    local wrong = helper.wrong

    helper.assert_blamed({
        {
            function()
                notices:recipient(wrong('users'))
            end,
            'модель адресата — таблица, а не строка',
        },
        {
            function()
                notices:recipient({})
            end,
            'модель адресата.space — непустая строка, а не nil',
        },
        {
            function()
                notices:recipient({ space = 'users' }, { keys = 'id' })
            end,
            'настройки адресата: ключа «keys» нет, есть addresses, key',
        },
        {
            function()
                notices:recipient({ space = 'users' }, { addresses = { mail = 'email' } })
            end,
            'настройки адресата.addresses: канала mail у центра нет',
        },
        {
            function()
                notices:recipient({ space = 'users' }, { addresses = { push = 5 } })
            end,
            'настройки адресата.addresses.push — строка или функция или вызываемая таблица, а не 5',
        },
    })
end

g.test_reading_goes_to_the_inbox_with_the_recipient = function()
    local users, calls = users_of()

    t.assert_equals(users:page({ id = 7 }), { items = {} })
    t.assert_equals(users:page('7', { limit = 100, after = '01K5', unread = true }), { items = {} })
    t.assert_equals(users:page(7, { limit = 1 }), { items = {} })
    t.assert_equals(users:unread(7), 3)
    t.assert_equals(users:mark_read(7, '01K5'), true)
    t.assert_equals(users:mark_all_read({ id = 7 }), 4)

    local ref = { type = 'users', id = '7' }

    t.assert_equals(calls, {
        { method = 'page', ref = ref, argument = { limit = 20 } },
        { method = 'page', ref = ref, argument = { limit = 100, after = '01K5', unread = true } },
        { method = 'page', ref = ref, argument = { limit = 1 } },
        { method = 'unread', ref = ref },
        { method = 'mark_read', ref = ref, argument = '01K5' },
        { method = 'mark_all_read', ref = ref },
    })
end

g.test_reading_checks_its_arguments_on_the_callers_line = function()
    local users = users_of()
    local bare = notification.new():recipient({ space = 'users' })

    helper.assert_blamed({
        {
            function()
                users:page(7, { limit = 0 })
            end,
            'настройки страницы.limit — число от 1 до 100, а не 0',
        },
        {
            function()
                users:page(7, { limit = 101 })
            end,
            'настройки страницы.limit — число от 1 до 100, а не 101',
        },
        {
            function()
                users:page(7, { after = '' })
            end,
            'настройки страницы.after — непустая строка, а не пустая',
        },
        {
            function()
                users:page(7, { unread = 'да' })
            end,
            'настройки страницы.unread — логическое значение, а не строка',
        },
        {
            function()
                users:page(7, { size = 5 })
            end,
            'настройки страницы: ключа «size» нет, есть after, limit, unread',
        },
        {
            function()
                users:mark_read(7, '')
            end,
            'опознаватель уведомления — непустая строка, а не пустая',
        },
        {
            function()
                bare:page(7)
            end,
            'уведомления без ящика: inbox центру не дали, и читать нечего',
        },
        {
            function()
                bare:unread(7)
            end,
            'уведомления без ящика: inbox центру не дали, и читать нечего',
        },
        {
            function()
                bare:mark_read(7, '01K5')
            end,
            'уведомления без ящика: inbox центру не дали, и читать нечего',
        },
        {
            function()
                bare:mark_all_read(7)
            end,
            'уведомления без ящика: inbox центру не дали, и читать нечего',
        },
    })
end
