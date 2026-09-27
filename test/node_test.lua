--- Уведомления на временном узле: ящик, страница, пометки, отправка одной
--- транзакцией и её отказы, настоящая очередь с письмом по шаблону
--- и перезапуском узла.
---
--- Двойника `box` здесь нет нарочно: транзакция, точка сохранения, узел
--- для чтения и откат синхронной транзакции приходят от настоящего ядра.
--- Каждая проверка берёт своих адресатов: спейс ящика живёт в одном узле
--- на весь набор.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.notification.node')

--- Заводит на узле сборщик центра: замыкания в `exec` не уезжают, а
--- повторять его в каждой проверке незачем.
---@param server table
local function prepare(server)
    server:exec(function()
        local notification = require('tnt.notification')

        notification.migration()(box)
        box.schema.space.create('scratch', { if_not_exists = true })
        box.space.scratch:create_index('primary', { if_not_exists = true })

        --- Центр с ящиком, каналом push и очередью: двойником либо данной.
        rawset(_G, 'build', function(opts)
            local given = opts or {}
            local sent, delivered = {}, {}
            local queue = given.queue
                or {
                    send = function(_, body)
                        if given.refuse ~= nil then
                            return nil, given.refuse
                        end

                        table.insert(sent, body)

                        return 'm-' .. #sent
                    end,
                }
            local push = {
                prepare = function(_, content, address)
                    if address == nil then
                        return nil
                    end

                    return { content = content, address = address }
                end,
                deliver = function(_, payload)
                    table.insert(delivered, payload)

                    return true
                end,
            }
            local notices = notification.new({
                inbox = notification.inbox({ space = given.space }),
                channels = { push = push },
                queue = queue,
            })

            notices:declare('replied', {
                via = { 'inbox', 'push' },
                inbox = function(data)
                    return { thread = data.thread }
                end,
                push = function(data)
                    return { thread = data.thread }
                end,
            })

            local users = notices:recipient({ space = given.type or 'users' }, { addresses = { push = 'device' } })

            return { notices = notices, users = users, sent = sent, delivered = delivered }
        end)

        --- Опознаватели по порядку: `n-01`, `n-02`… — порядок ящика по ним
        --- тот же, что у ULID.
        rawset(_G, 'numbered', function()
            local count = 0

            require('tnt.notification.center')._set_source({
                ulid = function()
                    count = count + 1

                    return ('n-%02d'):format(count)
                end,
                now = function()
                    return 1700000000 + count
                end,
            })
        end)
    end)
end

g.before_all(function()
    g.server = helper.start_node()
    prepare(g.server)
end)

g.after_all(function()
    helper.stop_node(g.server)
end)

g.after_each(function()
    g.server:exec(function()
        require('tnt.notification.center')._set_source(nil)
        require('tnt.notification.inbox')._set_source(nil)
        box.space.notifications:truncate()
        box.space.scratch:truncate()
    end)
end)

g.test_the_migration_is_safe_to_repeat = function()
    local seen = g.server:exec(function()
        local notification = require('tnt.notification')

        notification.migration()(box)
        notification.migration({ space = 'other_notifications' })(box)
        notification.migration({ space = 'other_notifications' })(box)

        local space = box.space.notifications
        local indexes = {}

        for name, index in pairs(space.index) do
            if type(name) == 'string' then
                local parts = {}

                for _, part in ipairs(index.parts) do
                    table.insert(parts, space:format()[part.fieldno].name)
                end

                indexes[name] = { parts = parts, unique = index.unique }
            end
        end

        return { indexes = indexes, other = box.space.other_notifications ~= nil, format = #space:format() }
    end)

    t.assert_equals(seen.indexes, {
        primary = { parts = { 'id' }, unique = true },
        recipient = { parts = { 'recipient_type', 'recipient_id', 'id' }, unique = true },
        unread = { parts = { 'recipient_type', 'recipient_id', 'read', 'id' }, unique = true },
    })
    t.assert_equals(seen.other, true)
    t.assert_equals(seen.format, 8)
end

g.test_a_notification_lands_in_the_inbox_and_the_queue = function()
    local seen = g.server:exec(function()
        _G.numbered()

        local center = _G.build()
        local report, err = center.users:notify({ id = 7, device = 'd-7' }, 'replied', { thread = 3 })

        return {
            report = report,
            err = err,
            page = center.users:page(7),
            unread = center.users:unread('7'),
            sent = center.sent,
            in_txn = box.is_in_txn(),
        }
    end)

    t.assert_equals(seen.err, nil)
    t.assert_equals(seen.report, { id = 'n-01', stored = { 'inbox' }, queued = { 'push' }, skipped = {} })
    t.assert_equals(seen.page, {
        items = {
            { id = 'n-01', kind = 'replied', data = { thread = 3 }, created = 1700000001, read = false },
        },
    })
    t.assert_equals(seen.unread, 1)
    t.assert_equals(seen.sent, {
        {
            id = 'n-01',
            kind = 'replied',
            created = 1700000001,
            recipient = { type = 'users', id = '7' },
            channel = 'push',
            payload = { content = { thread = 3 }, address = 'd-7' },
        },
    })
    t.assert_equals(seen.in_txn, false, 'своя транзакция закрыта')
end

g.test_a_recipient_without_an_address_skips_the_channel = function()
    local seen = g.server:exec(function()
        local center = _G.build()
        local report = center.users:notify({ id = 8 }, 'replied', { thread = 1 })

        return { report = report, sent = center.sent, unread = center.users:unread(8) }
    end)

    t.assert_equals(seen.report.stored, { 'inbox' })
    t.assert_equals(seen.report.queued, {})
    t.assert_equals(seen.report.skipped, { 'push' })
    t.assert_equals(seen.sent, {})
    t.assert_equals(seen.unread, 1)
end

g.test_a_notification_is_marked_read_only_by_its_recipient = function()
    local seen = g.server:exec(function()
        _G.numbered()
        require('tnt.notification.inbox')._set_source({
            now = function()
                return 1800000000
            end,
        })

        local center = _G.build()
        local users = center.users

        users:notify({ id = 7 }, 'replied', { thread = 1 })
        users:notify({ id = 9 }, 'replied', { thread = 2 })

        return {
            foreign = users:mark_read(9, 'n-01'),
            missing = users:mark_read(7, 'n-99'),
            first = users:mark_read(7, 'n-01'),
            again = users:mark_read(7, 'n-01'),
            unread = { users:unread(7), users:unread(9) },
            stored = (box.space.notifications:get('n-01') --[[@as table]]):tomap({ names_only = true }),
            page = users:page(7).items,
            unread_page = users:page(7, { unread = true }).items,
        }
    end)

    t.assert_equals(seen.foreign, false, 'чужое не помечается')
    t.assert_equals(seen.missing, false)
    t.assert_equals(seen.first, true)
    t.assert_equals(seen.again, false, 'отметка прочтения остаётся первой')
    t.assert_equals(seen.unread, { 0, 1 })
    t.assert_equals(seen.stored.read, true)
    t.assert_equals(seen.stored.read_at, 1800000000, 'отметка — в своём поле формата')
    t.assert_equals(seen.page, {
        {
            id = 'n-01',
            kind = 'replied',
            data = { thread = 1 },
            created = 1700000001,
            read = true,
            read_at = 1800000000,
        },
    })
    t.assert_equals(seen.unread_page, {})
end

g.test_everything_unread_is_marked_in_chunks = function()
    local seen = g.server:exec(function()
        local inbox = require('tnt.notification.inbox')
        local center = _G.build()
        local users = center.users

        for thread = 1, 5 do
            users:notify({ id = 7 }, 'replied', { thread = thread })
        end

        users:notify({ id = 9 }, 'replied', { thread = 6 })
        users:mark_read(7, users:page(7).items[1].id)

        local was = inbox.CHUNK

        inbox.CHUNK = 2

        local marked = users:mark_all_read(7)
        local after = { users:unread(7), users:unread(9) }

        users:notify({ id = 7 }, 'replied', { thread = 7 })
        users:notify({ id = 7 }, 'replied', { thread = 8 })

        box.begin()

        local inside = users:mark_all_read(7)
        local open = box.is_in_txn()

        box.rollback()

        inbox.CHUNK = was

        return {
            marked = marked,
            after = after,
            inside = inside,
            open = open,
            rolled = users:unread(7),
            nothing = users:mark_all_read(8),
        }
    end)

    t.assert_equals(seen.marked, 4, 'помеченное раньше не считается')
    t.assert_equals(seen.after, { 0, 1 }, 'чужое не тронуто')
    t.assert_equals(seen.inside, 2)
    t.assert_equals(seen.open, true, 'внутри чужой транзакции своей не открывает')
    t.assert_equals(seen.rolled, 2, 'пометка внутри транзакции — её часть')
    t.assert_equals(seen.nothing, 0)
end

g.test_pages_go_newest_first_with_a_cursor = function()
    local seen = g.server:exec(function()
        _G.numbered()

        local center = _G.build()
        local users = center.users

        -- Соседи с меньшим ключом: обратный обход страницы уходит к ним,
        -- и страница обязана на них кончиться.
        users:notify({ id = 6 }, 'replied', { thread = 0 })

        for thread = 1, 5 do
            users:notify({ id = 7 }, 'replied', { thread = thread })
        end

        users:mark_read(7, 'n-04')

        local function ids(page)
            local list = {}

            for _, item in ipairs(page.items) do
                table.insert(list, item.id)
            end

            return { ids = list, next = page.next }
        end

        return {
            first = ids(users:page(7, { limit = 2 })),
            second = ids(users:page(7, { limit = 2, after = 'n-05' })),
            last = ids(users:page(7, { limit = 2, after = 'n-03' })),
            exact = ids(users:page(7, { limit = 5 })),
            unread = ids(users:page(7, { limit = 2, unread = true })),
            unread_last = ids(users:page(7, { limit = 2, unread = true, after = 'n-03' })),
            neighbour = ids(users:page(6)),
        }
    end)

    t.assert_equals(seen.first, { ids = { 'n-06', 'n-05' }, next = 'n-05' })
    t.assert_equals(seen.second, { ids = { 'n-04', 'n-03' }, next = 'n-03' })
    t.assert_equals(seen.last, { ids = { 'n-02' } })
    t.assert_equals(seen.exact, { ids = { 'n-06', 'n-05', 'n-04', 'n-03', 'n-02' } })
    t.assert_equals(seen.unread, { ids = { 'n-06', 'n-05' }, next = 'n-05' })
    t.assert_equals(seen.unread_last, { ids = { 'n-02' } })
    t.assert_equals(seen.neighbour, { ids = { 'n-01' } })
end

g.test_a_page_ends_on_another_kind_of_recipient = function()
    local seen = g.server:exec(function()
        _G.numbered()

        -- Род `guests` меньше рода `members` при том же опознавателе:
        -- обратный обход после последнего уведомления уходит к нему.
        local guests = _G.build({ type = 'guests' }).users
        local members = _G.build({ type = 'members' }).users

        guests:notify({ id = 1 }, 'replied', { thread = 1 })
        members:notify({ id = 1 }, 'replied', { thread = 2 })

        return {
            after = members:page(1, { after = 'n-02' }).items,
            unread_after = members:page(1, { after = 'n-02', unread = true }).items,
            members = #members:page(1).items,
        }
    end)

    t.assert_equals(seen.after, {})
    t.assert_equals(seen.unread_after, {})
    t.assert_equals(seen.members, 1)
end

g.test_inside_a_transaction_the_notification_is_its_part = function()
    local seen = g.server:exec(function()
        local center = _G.build()

        box.begin()
        box.space.scratch:insert({ 1 })

        local report = center.users:notify({ id = 7 }, 'replied', { thread = 1 })
        local open = box.is_in_txn()

        box.rollback()

        return { report = report ~= nil, open = open, unread = center.users:unread(7) }
    end)

    t.assert_equals(seen.report, true)
    t.assert_equals(seen.open, true, 'транзакция вызывающего остаётся ему')
    t.assert_equals(seen.unread, 0, 'откат вызывающего унёс и уведомление')
end

g.test_a_refused_queue_rolls_back_only_the_notification = function()
    local seen = g.server:exec(function()
        local failure = require('tnt.storage').failure
        local refusal = failure.new(failure.UNREACHABLE, 'очередь не принимает')
        local center = _G.build({ refuse = refusal })
        local record = { id = 7, device = 'd-7' }

        -- Под pcall: бросок из отправки — провал проверки, а не падение
        -- самого luatest на разборе ошибки с узла.
        local _, report, err = pcall(center.users.notify, center.users, record, 'replied', { thread = 1 })
        local outside =
            { report = report, err = tostring(err), open = box.is_in_txn(), unread = center.users:unread(7) }

        box.begin()
        box.space.scratch:insert({ 1 })

        _, report, err = pcall(center.users.notify, center.users, record, 'replied', { thread = 2 })

        local inside = { report = report, err = tostring(err), open = box.is_in_txn() }

        if inside.open then
            box.commit()
        end

        inside.scratch = box.space.scratch:count()
        inside.unread = center.users:unread(7)

        return { outside = outside, inside = inside }
    end)

    t.assert_equals(seen.outside, { err = 'очередь не принимает', open = false, unread = 0 })
    t.assert_equals(
        seen.inside,
        { err = 'очередь не принимает', open = true, scratch = 1, unread = 0 }
    )
end

g.test_an_exception_of_the_queue_rolls_back_and_goes_up = function()
    local seen = g.server:exec(function()
        local center = _G.build({
            queue = {
                send = function()
                    error('тело не из простых данных', 0)
                end,
            },
        })
        local record = { id = 7, device = 'd-7' }

        local ok, err = pcall(center.users.notify, center.users, record, 'replied', { thread = 1 })
        local outside = { ok = ok, err = err, open = box.is_in_txn(), unread = center.users:unread(7) }

        box.begin()
        box.space.scratch:insert({ 1 })

        ok, err = pcall(center.users.notify, center.users, record, 'replied', { thread = 2 })

        local inside = { ok = ok, err = err, open = box.is_in_txn(), scratch = box.space.scratch:count() }

        box.commit()

        inside.unread = center.users:unread(7)

        return { outside = outside, inside = inside }
    end)

    t.assert_equals(
        seen.outside,
        { ok = false, err = 'тело не из простых данных', open = false, unread = 0 }
    )
    t.assert_equals(
        seen.inside,
        { ok = false, err = 'тело не из простых данных', open = true, scratch = 1, unread = 0 }
    )
end

g.test_a_read_only_node_refuses_to_write = function()
    local seen = g.server:exec(function()
        local center = _G.build()

        center.users:notify({ id = 7 }, 'replied', { thread = 1 })

        local id = center.users:page(7).items[1].id

        box.cfg({ read_only = true })

        local report, err = center.users:notify({ id = 7 }, 'replied', { thread = 2 })
        local marked, marked_err = center.users:mark_read(7, id)
        local all, all_err = center.users:mark_all_read(7)
        local page = center.users:page(7)

        box.cfg({ read_only = false })

        return {
            report = report,
            kind = err.kind,
            retriable = err.retriable,
            text = tostring(err),
            marked = { marked, tostring(marked_err) },
            all = { all, tostring(all_err) },
            readable = #page.items,
        }
    end)

    local refusal = 'ящик уведомлений не принимает: узел только для чтения'

    t.assert_equals(seen.report, nil)
    t.assert_equals(seen.kind, 'unreachable')
    t.assert_equals(seen.retriable, true)
    t.assert_equals(seen.text, refusal)
    t.assert_equals(seen.marked, { nil, refusal })
    t.assert_equals(seen.all, { nil, refusal })
    t.assert_equals(seen.readable, 1, 'читать узел для чтения даёт')
end

g.test_a_broken_write_is_a_repeatable_refusal = function()
    local seen = g.server:exec(function()
        require('tnt.notification.center')._set_source({
            now = function()
                return 'не число'
            end,
        })

        local center = _G.build()
        local report, err = center.users:notify({ id = 7, device = 'd-7' }, 'replied', { thread = 1 })

        return {
            report = report,
            kind = err.kind,
            retriable = err.retriable,
            reached = err.sent,
            text = tostring(err),
            sent = #center.sent,
            open = box.is_in_txn(),
        }
    end)

    t.assert_equals(seen.report, nil)
    t.assert_equals(seen.kind, 'broken')
    t.assert_equals(seen.retriable, true)
    t.assert_equals(
        seen.reached,
        false,
        'транзакция ящика откачена: запись не дошла'
    )
    t.assert_str_contains(
        seen.text,
        'ящик уведомлений: Tuple field 6 (created) type does not match one required'
    )
    t.assert_equals(seen.sent, 0, 'после отказа ящика очередь не тронута')
    t.assert_equals(seen.open, false)
end

g.test_a_commit_without_a_quorum_is_a_conflict = function()
    local seen = g.server:exec(function()
        local center = _G.build()

        box.ctl.promote()
        box.space.notifications:alter({ is_sync = true })
        box.cfg({ replication_synchro_quorum = 2, replication_synchro_timeout = 0.1 })

        local report, err = center.users:notify({ id = 7 }, 'replied', { thread = 1 })
        local open = box.is_in_txn()

        box.cfg({ replication_synchro_quorum = 1 })
        box.space.notifications:alter({ is_sync = false })

        return {
            report = report,
            kind = err.kind,
            retriable = err.retriable,
            reached = err.sent,
            text = tostring(err),
            open = open,
            unread = center.users:unread(7),
        }
    end)

    t.assert_equals(seen.report, nil)
    t.assert_equals(seen.kind, 'conflict')
    t.assert_equals(seen.retriable, false)
    t.assert_equals(seen.reached, false, 'без кворума транзакция откачена')
    t.assert_str_contains(seen.text, 'уведомление не легло: ')
    t.assert_equals(seen.open, false)
    t.assert_equals(seen.unread, 0)
end

g.test_a_missing_space_asks_for_the_migration = function()
    local seen = g.server:exec(function()
        local center = _G.build({ space = 'nowhere' })
        local users = center.users
        local calls = {
            function()
                return users:notify({ id = 7 }, 'replied', { thread = 1 })
            end,
            function()
                return users:page(7)
            end,
            function()
                return users:unread(7)
            end,
            function()
                return users:mark_read(7, 'n-01')
            end,
            function()
                return users:mark_all_read(7)
            end,
        }
        local errors = {}

        for _, call in ipairs(calls) do
            local _, err = pcall(call)

            table.insert(errors, err)
        end

        return { errors = errors, open = box.is_in_txn() }
    end)

    local text =
        'ящик уведомлений: спейса nowhere нет — нужен шаг миграции notification.migration()'

    t.assert_equals(seen.errors, { text, text, text, text, text })
    t.assert_equals(seen.open, false)
end

g.test_the_default_chunk_is_named = function()
    local chunk = g.server:exec(function()
        return require('tnt.notification.inbox').CHUNK
    end)

    t.assert_equals(chunk, 500)
end

--- Узел с настоящей очередью: письмо по шаблону уходит работником,
--- переживает перезапуск и повторяется после временного отказа.
local queued = t.group('tnt.notification.queued')

queued.before_all(function()
    queued.server = helper.start_node()
    prepare(queued.server)
end)

queued.after_all(function()
    helper.stop_node(queued.server)
end)

--- Заводит на узле центр с письмами по шаблону и настоящей очередью.
---@param server table
local function mailing(server)
    server:exec(function()
        local fio = require('fio')
        local notification = require('tnt.notification')
        local template = require('tnt.template')

        local views = fio.pathjoin(fio.cwd(), 'views')

        fio.mktree(fio.pathjoin(views, 'mail'))

        local file = fio.open(fio.pathjoin(views, 'mail', 'replied.thtml.lua'), { 'O_CREAT', 'O_WRONLY', 'O_TRUNC' })

        file:write('<p>{{ name }}, вам ответили в теме {{ thread }}</p>')
        file:close()

        notification.migration()(box)

        rawset(_G, 'letters', rawget(_G, 'letters') or {})
        rawset(_G, 'answers', rawget(_G, 'answers') or {})

        local mailer = {
            send = function(letter)
                table.insert(_G.letters, letter)

                local answer = table.remove(_G.answers, 1) or { true }

                return answer[1], answer[2]
            end,
        }

        local queue = require('tnt.queue').declare('notices', { ttr = 5 })
        local notices = notification.new({
            inbox = notification.inbox(),
            channels = { mail = notification.mail({ mailer = mailer, views = template.new({ path = views }) }) },
            queue = queue,
        })

        notices:declare('replied', {
            via = { 'inbox', 'mail' },
            inbox = function(data)
                return { thread = data.thread }
            end,
            mail = function(data, user)
                return {
                    subject = 'Вам ответили',
                    view = 'mail.replied',
                    data = { name = user.name, thread = data.thread },
                }
            end,
        })

        rawset(_G, 'queue', queue)
        rawset(_G, 'notices', notices)
        rawset(_G, 'users', notices:recipient({ space = 'users' }, { addresses = { mail = 'email' } }))
    end)
end

--- Ждёт на узле, пока писем не станет столько.
---@param server table
---@param count integer
---@return table[] letters
local function letters(server, count)
    return server:exec(function(wanted)
        local fiber = require('fiber')
        local deadline = fiber.clock() + 5

        while #_G.letters < wanted and fiber.clock() < deadline do
            fiber.sleep(0.01)
        end

        return _G.letters
    end, { count })
end

queued.test_a_letter_by_template_survives_a_restart = function()
    local server = queued.server

    mailing(server)

    local report = server:exec(function()
        return _G.users:notify({ id = 7, name = 'Мария', email = 'maria@example.org' }, 'replied', { thread = 3 })
    end)

    t.assert_equals(report.stored, { 'inbox' })
    t.assert_equals(report.queued, { 'mail' })

    server:restart()
    helper.reload(server)
    mailing(server)

    local unread = server:exec(function()
        rawset(_G, 'consumer', _G.queue:consume(_G.notices:handler()))

        return _G.users:unread(7)
    end)

    local sent = letters(server, 1)

    t.assert_equals(unread, 1, 'ящик пережил перезапуск')
    local letter = sent[1] --[[@as table]]

    t.assert_equals(#sent, 1)
    t.assert_equals(letter.to, 'maria@example.org')
    t.assert_equals(letter.subject, 'Вам ответили')
    t.assert_equals(letter.html, '<p>Мария, вам ответили в теме 3</p>')
    t.assert_equals(letter.headers, { ['X-Notification-Id'] = report.id })

    server:exec(function()
        _G.consumer:stop()
    end)
end

queued.test_a_temporary_refusal_is_repeated_and_a_permanent_one_is_buried = function()
    local server = queued.server

    mailing(server)

    local seen = server:exec(function()
        local fiber = require('fiber')

        rawset(_G, 'letters', {})
        rawset(_G, 'answers', {
            { false, 'данные: сервер ответил 451 — 451 4.3.0 try later' },
            { true },
            {
                false,
                'получатель x@example.org: сервер ответил 550 — 550 5.1.1 mailbox unavailable',
            },
        })

        local consumer = _G.queue:consume(_G.notices:handler(), { backoff = { base = 0.05, max = 0.05 } })

        _G.users:notify({ id = 8, name = 'Пётр', email = 'petr@example.org' }, 'replied', { thread = 1 })

        local deadline = fiber.clock() + 5

        while #_G.letters < 2 and fiber.clock() < deadline do
            fiber.sleep(0.01)
        end

        _G.users:notify({ id = 9, name = 'Анна', email = 'x@example.org' }, 'replied', { thread = 2 })

        while box.space.notices_dead:count() < 1 and fiber.clock() < deadline do
            fiber.sleep(0.01)
        end

        consumer:stop()

        local dead = box.space.notices_dead:select()[1]

        return { letters = #_G.letters, reason = dead and dead.reason, attempt = dead and dead.attempt }
    end)

    t.assert_equals(
        seen.letters,
        3,
        'временный отказ повторён, постоянный — одна попытка'
    )
    t.assert_str_contains(
        seen.reason,
        'письмо не отправлено: получатель x@example.org: сервер ответил 550'
    )
    t.assert_equals(seen.attempt, 1, 'постоянный отказ зарыт сразу')
end

queued.test_a_rolled_back_notification_leaves_the_queue_empty = function()
    local server = queued.server

    mailing(server)

    local seen = server:exec(function()
        box.begin()
        _G.users:notify({ id = 10, name = 'Ольга', email = 'olga@example.org' }, 'replied', { thread = 4 })
        box.rollback()

        return { ready = _G.queue:status().depth.ready, unread = _G.users:unread(10) }
    end)

    t.assert_equals(seen, { ready = 0, unread = 0 })
end
