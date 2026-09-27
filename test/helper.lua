--- Общие средства проверок уведомлений.
---
--- Чистые части — объявление видов, адресат, каналы писем и вебхука —
--- проверяются в процессе, на двойниках почты, клиента HTTP и очереди.
--- Ящик и отправка одной транзакцией держатся на настоящем `box`,
--- и их проверяет временный узел: двойник спейса и транзакции доказал бы
--- лишь, что мы правильно разговариваем сами с собой. Там же — настоящая
--- очередь `tnt-queue`, переживающая перезапуск узла, и настоящие шаблоны
--- `tnt-template`.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.must`, `tnt.storage`, `tnt.id`, `tnt.clock`, `tnt.hash`,
--- `tnt.external` — берутся из `.rocks` обычным `require`: проверяется
--- этот пакет, а не они. Очередь и шаблоны пакету приходят аргументами,
--- и `make deps` ставит их в `.rocks` рядом с зависимостями; на временном
--- узле всё это берётся так же.
---
--- Оснастка в `test/testing/` — загрузчик исходников, запись файлов
--- и временный узел — грузится так же, файлами, и один раз на процесс:
--- второй экземпляр загрузчика не знал бы, что вытеснил первый, и не вернул
--- бы вытесненное на место.
---
--- Проверки берут всё через этот помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- в наборе, где пакет живёт рядом со своими зависимостями.

local fio = require('fio')
local t = require('luatest')

--- Модули оснастки в порядке зависимостей: узел берёт файлы и загрузчик.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.files', path = 'test/testing/files.lua' },
    { name = 'tnt.testing.node', path = 'test/testing/node.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    absolute = package.loaded['tnt.testing.sources'].absolute,
    start_node = package.loaded['tnt.testing.node'].start,
    stop_node = package.loaded['tnt.testing.node'].stop,
}

--- Модули пакета в порядке зависимостей.
local OWN = {
    { name = 'tnt.notification.inbox', path = 'tnt/notification/inbox.lua' },
    { name = 'tnt.notification.recipient', path = 'tnt/notification/recipient.lua' },
    { name = 'tnt.notification.center', path = 'tnt/notification/center.lua' },
    { name = 'tnt.notification.mail', path = 'tnt/notification/mail.lua' },
    { name = 'tnt.notification.webhook', path = 'tnt/notification/webhook.lua' },
    { name = 'tnt.notification', path = 'tnt/notification.lua' },
}

--- Средства проверок уведомлений.
---@class TntNotificationTestHelper
---@field notification table Фасад пакета
---@field MODULES table[] Исходники пакета
local helper = { MODULES = OWN }

--- Модули узла: те же исходники пакета — очередь и шаблоны узел берёт
--- из `.rocks`, как и зависимости.
helper.NODE_MODULES = OWN

--- Фасад пакета из исходников. Отказ хранилища — из `.rocks`: пакет берёт
--- его оттуда же, и род отказа сверяется с тем же экземпляром.
helper.notification = testing.load_sources(helper.MODULES, 'tnt.notification')
helper.failure = require('tnt.storage').failure

--- Хеши из той же загрузки, что и у пакета: подпись вебхука сверяется
--- с HMAC, посчитанным независимо от канала.
helper.hash = require('tnt.hash')

--- Значение мимо проверки типов: негодный аргумент нарочно.
---@param value any
---@return any
function helper.wrong(value)
    return value
end

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- вызова в файле проверок, а не внутри пакета.
---
--- Вызов стоит в замыкании первой строкой тела, то есть строкой ниже
--- слова `function`: место броска сверяется с ней целиком — файлом,
--- строкой и текстом.
---@param cases table[] Пары: замыкание с вызовом и текст броска
function helper.assert_blamed(cases)
    for _, case in ipairs(cases) do
        local _, err = pcall(case[1])
        local info = debug.getinfo(case[1], 'S') --[[@as { short_src: string, linedefined: integer }]]

        t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, case[2]))
    end
end

--- Поднимает временный узел с исходниками пакета; очередь и шаблоны
--- на нём — из `.rocks`. Узел проверка обязана остановить сама — `stop_node`.
---@return table server
function helper.start_node()
    return testing.start_node({ modules = helper.NODE_MODULES })
end

--- Грузит исходники на узел заново: перезапуск снимает их вместе
--- со строгим режимом глобалов.
---@param server table
function helper.reload(server)
    server:exec(function(modules)
        require('strict').on()

        for _, module in ipairs(modules) do
            package.loaded[module.name] = assert(loadfile(module.path))()
        end
    end, { testing.absolute(helper.NODE_MODULES) })
end

--- Останавливает узел и убирает его каталог.
helper.stop_node = testing.stop_node

--- Двойник очереди по договору: помнит отправленное.
---@param answers table|nil Что отдаёт `send`: `{ 'id-1' }` либо `{ nil, err }`
---@return table queue
---@return table sent Отправленное по порядку
function helper.queue(answers)
    local sent = {}
    local answer = answers or { 'msg-1' }

    return {
        send = function(_, body)
            table.insert(sent, body)

            return answer[1], answer[2]
        end,
    },
        sent
end

--- Двойник почты: помнит письма и отвечает заготовленным.
---@param answer table|nil `{ true }` либо `{ false, 'причина' }`
---@return table mailer
---@return table letters Отправленные письма по порядку
function helper.mailer(answer)
    local letters = {}
    local scripted = answer or { true }

    return {
        send = function(letter)
            table.insert(letters, letter)

            return scripted[1], scripted[2]
        end,
    },
        letters
end

--- Двойник движка шаблонов: рисует имя и данные строкой.
---@return table views
---@return table calls Нарисованное по порядку: `{ name, data }`
function helper.views()
    local calls = {}

    return {
        render = function(_, name, data)
            table.insert(calls, { name = name, data = data })

            return ('[%s:%s]'):format(name, tostring(data.name))
        end,
    },
        calls
end

--- Двойник клиента HTTP: помнит запросы и отвечает заготовленным.
---@param answer table `{ response }` либо `{ nil, err }`
---@return table client
---@return table calls Запросы по порядку: `{ url, opts }`
function helper.client(answer)
    local calls = {}

    return {
        post = function(_, url, opts)
            table.insert(calls, { url = url, opts = opts })

            return answer[1], answer[2]
        end,
    },
        calls
end

--- Ответ HTTP с кодом.
---@param status integer
---@return table
function helper.response(status)
    return {
        status = status,
        ok = function(self)
            return self.status >= 200 and self.status < 300
        end,
    }
end

--- Уведомление, как его видят каналы.
---@param overrides table|nil
---@return table
function helper.notice(overrides)
    local notice = {
        id = '01K5Z0000000000000000000AB',
        kind = 'replied',
        created = 1700000000.5,
        recipient = { type = 'users', id = '7' },
    }

    for key, value in pairs(overrides or {}) do
        notice[key] = value
    end

    return notice
end

return helper
