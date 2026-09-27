--- Канал вебхука в процессе: тело JSON, адрес адресата и общий,
--- подпись тела, приговор повтору по коду ответа и отказу сети.

local json = require('json')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local notification = helper.notification
local failure = helper.failure
local hash = helper.hash

local g = t.group('tnt.notification.webhook')

g.test_the_body_carries_the_notice_and_the_view = function()
    local channel = notification.webhook({ client = helper.client({}) })

    local request = channel:prepare({ thread = 7 }, 'https://hooks.example.org/u7', helper.notice())

    t.assert_equals(request.url, 'https://hooks.example.org/u7')
    t.assert_equals(request.id, '01K5Z0000000000000000000AB')
    t.assert_equals(json.decode(request.body), {
        id = '01K5Z0000000000000000000AB',
        kind = 'replied',
        created = 1700000000.5,
        recipient = { type = 'users', id = '7' },
        data = { thread = 7 },
    })
end

g.test_the_common_address_serves_a_recipient_without_one = function()
    local common = notification.webhook({ client = helper.client({}), url = 'https://push.example.org' })
    local lonely = notification.webhook({ client = helper.client({}) })

    t.assert_equals(common:prepare({}, nil, helper.notice()).url, 'https://push.example.org')
    t.assert_equals(common:prepare({}, 'https://own.example.org', helper.notice()).url, 'https://own.example.org')
    t.assert_equals(lonely:prepare({}, nil, helper.notice()), nil)
end

g.test_a_bad_body_names_the_kind_of_notification = function()
    local channel = notification.webhook({ client = helper.client({}) })
    local cases = {
        { 'тело', nil, 'тело вебхука — таблица, а не строка' },
        { {}, '', 'адрес вебхука — непустая строка, а не пустая' },
    }

    for _, case in ipairs(cases) do
        local ok, err = pcall(channel.prepare, channel, case[1], case[2], helper.notice())

        t.assert_equals({ ok, err }, { false, 'уведомление replied: ' .. case[3] })
    end
end

g.test_a_request_goes_once_with_its_headers_and_signature = function()
    local client, calls = helper.client({ helper.response(204) })
    local channel = notification.webhook({
        client = client,
        secret = 'тайна',
        headers = { authorization = 'Bearer t', ['content-type'] = 'text/plain' },
    })

    local sent, err = channel:deliver({ url = 'https://hooks.example.org', body = '{"id":"n-1"}', id = 'n-1' })

    t.assert_equals({ sent, err }, { true, nil })
    t.assert_equals(calls, {
        {
            url = 'https://hooks.example.org',
            opts = {
                body = '{"id":"n-1"}',
                retry = { attempts = 1 },
                headers = {
                    authorization = 'Bearer t',
                    ['content-type'] = 'application/json',
                    ['x-notification-id'] = 'n-1',
                    ['x-notification-signature'] = 'sha256='
                        .. hash.hmac('sha256', 'тайна', '{"id":"n-1"}', 'hex'),
                },
            },
        },
    })

    channel:deliver({ url = 'https://hooks.example.org', body = '{}', id = 'n-2' })

    t.assert_equals(
        calls[2].opts.headers['x-notification-id'],
        'n-2',
        'заголовки канала не копят чужих'
    )
    t.assert_equals(channel.headers, { authorization = 'Bearer t', ['content-type'] = 'text/plain' })
end

g.test_without_a_secret_there_is_no_signature = function()
    local client, calls = helper.client({ helper.response(200) })
    local channel = notification.webhook({ client = client })

    channel:deliver({ url = 'https://hooks.example.org', body = '{}', id = 'n-1' })

    t.assert_equals(calls[1].opts.headers, { ['content-type'] = 'application/json', ['x-notification-id'] = 'n-1' })
end

g.test_the_status_decides_the_repeat = function()
    local cases = {
        { 199, failure.REJECTED, false },
        { 300, failure.REJECTED, false },
        { 404, failure.REJECTED, false },
        { 429, failure.BUSY, true },
        { 500, failure.BROKEN, true },
        { 503, failure.BUSY, true },
    }

    for _, case in ipairs(cases) do
        local channel = notification.webhook({ client = helper.client({ helper.response(case[1]) }) })
        local sent, err = channel:deliver({ url = 'https://hooks.example.org', body = '{}', id = 'n-1' })

        t.assert_equals(sent, nil)
        t.assert_equals(err.kind, case[2], case[1])
        t.assert_equals(err.retriable, case[3], case[1])
        t.assert_equals(err.server_code, case[1])
        t.assert_equals(tostring(err), ('вебхук ответил %d'):format(case[1]))
    end
end

g.test_a_network_refusal_is_repeated = function()
    local refusal = { kind = 'unreachable', message = "Couldn't connect to server" }
    local channel = notification.webhook({ client = helper.client({ nil, refusal }) })

    local sent, err = channel:deliver({ url = 'https://hooks.example.org', body = '{}', id = 'n-1' })

    t.assert_equals(sent, nil)
    t.assert_equals(err.kind, failure.UNREACHABLE)
    t.assert_equals(err.retriable, true)

    local timeout = notification.webhook({
        client = helper.client({ nil, { kind = 'unreachable', message = 'Timeout was reached' } }),
    })

    sent, err = timeout:deliver({ url = 'https://hooks.example.org', body = '{}', id = 'n-1' })

    t.assert_equals(sent, nil)
    t.assert_equals(err.kind, failure.TIMEOUT)
    t.assert_equals(
        err.retriable,
        true,
        'повтор после отправки: получатель отсекает его по id'
    )
end

g.test_the_channel_checks_its_settings_on_the_callers_line = function()
    local wrong = helper.wrong

    helper.assert_blamed({
        {
            function()
                notification.webhook(wrong(nil))
            end,
            'настройки канала вебхука — таблица, а не nil',
        },
        {
            function()
                notification.webhook({ client = helper.client({}), link = 'x' })
            end,
            'настройки канала вебхука: ключа «link» нет, есть client, headers, secret, url',
        },
        {
            function()
                notification.webhook({ client = {} })
            end,
            'настройки канала вебхука.client.post — функция или вызываемая таблица, а не nil',
        },
    })
end
