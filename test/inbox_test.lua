--- Ящик в процессе: настройки ящика и шага миграции.
---
--- Сам ящик держится на настоящем `box` и проверяется на узле
--- (`node_test.lua`); здесь — что решается до него.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local notification = helper.notification

local g = t.group('tnt.notification.inbox')

g.test_the_space_is_a_setting = function()
    t.assert_equals(notification.inbox().name, 'notifications')
    t.assert_equals(notification.inbox({ space = 'user_notices' }).name, 'user_notices')
    t.assert_type(notification.migration(), 'function')
end

g.test_the_settings_are_checked_on_the_callers_line = function()
    helper.assert_blamed({
        {
            function()
                notification.inbox({ spaces = 'user_notices' })
            end,
            'настройки ящика: ключа «spaces» нет, есть space',
        },
        {
            function()
                notification.migration({ space = '' })
            end,
            'настройки ящика.space — непустая строка, а не пустая',
        },
    })
end
