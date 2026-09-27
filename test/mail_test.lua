--- Канал писем в процессе: сборка письма из вида, шаблоны, отправка
--- почтой-двойником и приговор повтору по коду SMTP.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local notification = helper.notification
local failure = helper.failure

local g = t.group('tnt.notification.mail')

g.test_a_letter_is_built_from_the_view = function()
    local mailer = helper.mailer()
    local channel = notification.mail({ mailer = mailer, from = 'noreply@example.org' })

    local letter = channel:prepare(
        { subject = 'Вам ответили', text = 'Текст', html = '<p>Текст</p>' },
        { name = 'Мария', address = 'maria@example.org' },
        helper.notice()
    )

    t.assert_equals(letter, {
        to = { name = 'Мария', address = 'maria@example.org' },
        from = 'noreply@example.org',
        subject = 'Вам ответили',
        text = 'Текст',
        html = '<p>Текст</p>',
        headers = { ['X-Notification-Id'] = '01K5Z0000000000000000000AB' },
    })
end

g.test_the_bodies_are_drawn_by_the_views = function()
    local views, calls = helper.views()
    local channel = notification.mail({ mailer = helper.mailer(), views = views })

    local letter = channel:prepare({
        subject = 'Вам ответили',
        view = 'mail.replied',
        text_view = 'mail.replied_text',
        data = { name = 'Мария' },
    }, 'maria@example.org', helper.notice())

    t.assert_equals(letter.html, '[mail.replied:Мария]')
    t.assert_equals(letter.text, '[mail.replied_text:Мария]')
    t.assert_equals(calls, {
        { name = 'mail.replied_text', data = { name = 'Мария' } },
        { name = 'mail.replied', data = { name = 'Мария' } },
    })

    local bare = channel:prepare({ subject = 'Тема', view = 'mail.bare' }, 'maria@example.org', helper.notice())

    t.assert_equals(bare.html, '[mail.bare:nil]')
    t.assert_equals(bare.text, nil)
    t.assert_equals(calls[3], { name = 'mail.bare', data = {} })
end

g.test_no_address_means_no_letter = function()
    local channel = notification.mail({ mailer = helper.mailer() })

    t.assert_equals(channel:prepare({ subject = 'Тема', text = 'Текст' }, nil, helper.notice()), nil)
end

g.test_a_bad_letter_names_the_kind_of_notification = function()
    local channel = notification.mail({ mailer = helper.mailer() })
    local cases = {
        { { text = 'Текст' }, 'maria@example.org', 'письмо.subject — строка, а не nil' },
        {
            { subject = 'Тема', body = 'x' },
            'maria@example.org',
            'письмо: ключа «body» нет, есть data, html, subject, text, text_view, view',
        },
        {
            { subject = 'Тема', text = 'Текст' },
            5,
            'адрес письма — строка или таблица, а не 5',
        },
        {
            { subject = 'Тема' },
            'maria@example.org',
            'у письма нет тела — дайте text, html, view либо text_view',
        },
        {
            { subject = 'Тема', view = 'mail.replied' },
            'maria@example.org',
            'письмо по шаблону mail.replied, а views каналу писем не дали',
        },
    }

    for _, case in ipairs(cases) do
        local ok, err = pcall(channel.prepare, channel, case[1], case[2], helper.notice())

        t.assert_equals({ ok, err }, { false, 'уведомление replied: ' .. case[3] })
    end
end

g.test_a_sent_letter_is_a_success = function()
    local mailer, letters = helper.mailer()
    local channel = notification.mail({ mailer = mailer })

    t.assert_equals({ channel:deliver({ to = 'maria@example.org' }) }, { true })
    t.assert_equals(letters, { { to = 'maria@example.org' } })
end

g.test_a_permanent_refusal_is_buried_and_a_temporary_one_is_repeated = function()
    local permanent = notification.mail({
        mailer = helper.mailer({
            false,
            'получатель x@example.org: сервер ответил 550 — 550 5.1.1 mailbox unavailable',
        }),
    })
    local temporary = notification.mail({
        mailer = helper.mailer({ false, 'данные: сервер ответил 451 — 451 4.3.0 try later' }),
    })
    local silent = notification.mail({ mailer = helper.mailer({ false }) })

    local sent, err = permanent:deliver({})

    t.assert_equals(sent, nil)
    t.assert_equals(err.kind, failure.REJECTED)
    t.assert_equals(err.retriable, false)
    t.assert_equals(
        tostring(err),
        'письмо не отправлено: получатель x@example.org: сервер ответил 550 — 550 5.1.1 mailbox unavailable'
    )

    sent, err = temporary:deliver({})

    t.assert_equals(sent, nil)
    t.assert_equals(err.kind, failure.BROKEN)
    t.assert_equals(err.retriable, true)
    t.assert_equals(
        tostring(err),
        'письмо не отправлено: данные: сервер ответил 451 — 451 4.3.0 try later'
    )

    sent, err = silent:deliver({})

    t.assert_equals(sent, nil)
    t.assert_equals(err.retriable, true)
    t.assert_equals(tostring(err), 'письмо не отправлено: nil')
end

g.test_the_channel_checks_its_settings_on_the_callers_line = function()
    local wrong = helper.wrong

    helper.assert_blamed({
        {
            function()
                notification.mail(wrong(nil))
            end,
            'настройки канала писем — таблица, а не nil',
        },
        {
            function()
                notification.mail({ mailer = helper.mailer(), sender = 'x' })
            end,
            'настройки канала писем: ключа «sender» нет, есть from, mailer, views',
        },
        {
            function()
                notification.mail({ mailer = {} })
            end,
            'настройки канала писем.mailer.send — функция или вызываемая таблица, а не nil',
        },
    })
end
