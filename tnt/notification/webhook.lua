--- Канал вебхука: уведомление уходит POST-запросом с телом JSON.
---
--- Клиент HTTP приходит аргументом `client` — таблицей с методом
--- `post(url, opts)`, отвечающим как клиент `tnt-http`. Адрес — у адресата
--- (его адрес канала) либо общий у канала (`url`): так один канал служит
--- и вебхукам, которые заводят сами пользователи, и одной службе
--- рассылки на всех.
---
--- Тело собирается при отправке уведомления и едет в очереди строкой —
--- ровно то, что уйдёт и что подписывается: `{ id, kind, created,
--- recipient, data }`. По `id` получатель отсекает повтор: доставка —
--- «хотя бы раз», и тот же запрос приходит снова после обрыва и после
--- опоздавшего итога.
---
--- С настройкой `secret` запрос несёт подпись HMAC-SHA256 тела
--- в заголовке `x-notification-signature: sha256=<hex>`. Тайна в очередь
--- не попадает: подпись считается работником перед самой отправкой.
---
--- Повторов у запроса нет, и это решение канала: повторяет очередь,
--- с отступом и потолком попыток, а два цикла повторов друг в друге
--- множили бы попытки. Род отказа — по коду ответа, как у драйверов поверх
--- HTTP (`failure.status`): 429 и 503 — `busy`, прочие 5xx — `broken`,
--- и оба повторяются, как и отказ сети; остальные 4xx — `rejected`,
--- `denied` либо `conflict`, и сообщение зарывается сразу: это тело чужая
--- служба не примет и через час.
---
--- Адрес, взятый у адресата, приходит от пользователя. Пакет не судит,
--- куда можно ходить узлу: запрет внутренних адресов — дело приложения,
--- которое этот адрес принимает.

local json = require('json')

local hash = require('tnt.hash')
local must = require('tnt.must')

--- Отказ запроса — родом хранилища: код ответа и отказ сети переводит
--- `tnt-storage` так же, как у драйверов поверх HTTP.
local failure = require('tnt.storage').failure

local Module = {}

--- Бросок без места: негодное тело собрал вид уведомления.
local fail = require('tnt.must.fail').raise

--- Заголовок с опознавателем уведомления.
Module.ID_HEADER = 'x-notification-id'

--- Заголовок с подписью тела.
Module.SIGNATURE_HEADER = 'x-notification-signature'

--- Настройки канала. Незнакомый ключ — исключение.
local OPTIONS = { client = 'table', url = '?not_empty', secret = '?not_empty', headers = '?table' }

--- Повторы запроса выключены: повторяет очередь.
local SINGLE = { attempts = 1 }

---@class TntNotificationWebhook Канал вебхука
---@field client table Клиент HTTP с методом `post`
---@field url string|nil Общий адрес: им служит канал адресату без своего
---@field secret string|nil Ключ подписи тела
---@field headers table<string, string> Свои заголовки запроса
local Webhook = {}
Webhook.__index = Webhook

--- Готовит запрос: адрес и тело JSON.
---
--- Адреса нет ни у адресата, ни у канала — запроса нет: `nil`, и канал
--- для этого адресата пропущен.
---@param content table Что отдал вид уведомления
---@param address string|nil Адрес адресата
---@param notice { id: string, kind: string, created: number, recipient: table }
---@return { url: string, body: string, id: string }|nil
function Webhook:prepare(content, address, notice)
    local complaint = must.explain.kind(content, 'тело вебхука', 'table')
        or must.explain.kind(address, 'адрес вебхука', '?not_empty')

    if complaint ~= nil then
        fail(('уведомление %s: %s'):format(notice.kind, complaint))
    end

    local url = address or self.url

    if url == nil then
        return nil
    end

    local body = json.encode({
        id = notice.id,
        kind = notice.kind,
        created = notice.created,
        recipient = notice.recipient,
        data = content,
    })

    return { url = url, body = body, id = notice.id }
end

--- Отправляет запрос.
---@param request { url: string, body: string, id: string }
---@return boolean|nil sent
---@return TntStorageFailure|nil err
function Webhook:deliver(request)
    local headers = table.copy(self.headers)

    headers['content-type'] = 'application/json'
    headers[Module.ID_HEADER] = request.id

    if self.secret ~= nil then
        headers[Module.SIGNATURE_HEADER] = 'sha256=' .. hash.hmac('sha256', self.secret, request.body, 'hex')
    end

    local response, err = self.client:post(request.url, { body = request.body, headers = headers, retry = SINGLE })

    if response == nil then
        return nil, failure.http(err, { idempotent = true })
    end

    if not response:ok() then
        local text = ('вебхук ответил %s'):format(tostring(response.status))

        return nil, failure.status(response.status, text, { idempotent = true })
    end

    return true
end

--- Заводит канал вебхука.
---@param opts { client: table, url: string|nil, secret: string|nil, headers: table|nil }
---@return TntNotificationWebhook
function Module.new(opts)
    local caller = must.at(2)

    caller.options(opts, 'настройки канала вебхука', OPTIONS)
    caller.callable(opts.client.post, 'настройки канала вебхука.client.post')

    return setmetatable({
        client = opts.client,
        url = opts.url,
        secret = opts.secret,
        headers = opts.headers or {},
    }, Webhook)
end

return Module
