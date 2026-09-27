--- Канал писем: уведомление уходит письмом через почту узла.
---
--- Почта приходит аргументом `mailer` — таблицей с функцией
--- `send(letter) → true | false, err`; `require('tnt.mail')` такая и есть.
--- От пакета почты уведомления не зависят: канал знает договор отправки,
--- а не того, кто его держит.
---
--- Письмо собирается при отправке уведомления, в файбере вызывающего:
--- вид уведомления отдаёт тему и тело либо имена шаблонов, и шаблоны
--- рисует `views` — движок `tnt-template`, пришедший аргументом. В очередь
--- уходит готовое письмо простыми данными, и работник только отправляет
--- его: ошибка в шаблоне падает у того, кто отправлял, а не зарытым
--- сообщением через час.
---
--- Отказ почты — строка, и код SMTP в ней решает повтор: `5xx` — адреса
--- нет или отказано навсегда, такое письмо зарывается сразу; прочее —
--- сервер занят, сеть, — повторяется очередью. Отправка письма дважды
--- (опоздавший итог, повтор после обрыва) считается допустимой ценой
--- «хотя бы раза».

--- Бросок без места: негодное письмо собрал вид уведомления, и текст
--- называет вид — строка вызова пакета тут ничего не скажет.
local fail = require('tnt.must.fail').raise
local must = require('tnt.must')

--- Отказ отправки — родом хранилища: по `retriable` очередь решает повтор.
local failure = require('tnt.storage').failure

local Module = {}

--- Заголовок с опознавателем уведомления: по нему получатель и почтовые
--- правила узнают повтор того же уведомления.
Module.HEADER = 'X-Notification-Id'

--- Настройки канала. Незнакомый ключ — исключение.
local OPTIONS = { mailer = 'table', views = '?table', from = '?string|table' }

--- Что отдаёт вид уведомления для письма. Незнакомый ключ — исключение.
local LETTER = {
    subject = 'string',
    text = '?string',
    html = '?string',
    view = '?not_empty',
    text_view = '?not_empty',
    data = '?table',
}

--- Код SMTP «не пробуйте больше» в тексте отказа почты.
local PERMANENT = 'ответил 5%d%d'

---@class TntNotificationMail Канал писем
---@field mailer { send: fun(letter: table): boolean, any }
---@field views table|nil Движок шаблонов с методом `render(name, data)`
---@field from any Отправитель поверх настроек почты
local Mail = {}
Mail.__index = Mail

--- Бросает отказ о письме с именем вида уведомления.
---@param notice { kind: string }
---@param complaint string
local function refuse(notice, complaint)
    fail(('уведомление %s: %s'):format(notice.kind, complaint))
end

--- Тело письма по шаблону либо как дано.
---@param self TntNotificationMail
---@param notice { kind: string }
---@param text string|nil Готовое тело
---@param view string|nil Имя шаблона
---@param data table|nil Данные шаблона
---@return string|nil
local function body_of(self, notice, text, view, data)
    if view == nil then
        return text
    end

    if self.views ~= nil then
        return self.views:render(view, data or {})
    end

    refuse(notice, ('письмо по шаблону %s, а views каналу писем не дали'):format(view))
end

--- Готовит письмо: тема и тело из вида, получатель — адрес адресата.
---
--- Адреса нет — письма нет: `nil`, и канал для этого адресата пропущен.
---@param content table Что отдал вид уведомления
---@param address any Адрес: строка либо `{ name, address }`
---@param notice { id: string, kind: string }
---@return table|nil letter
function Mail:prepare(content, address, notice)
    local complaint = must.explain.options(content, 'письмо', LETTER)
        or must.explain.kind(address, 'адрес письма', '?string|table')

    if complaint ~= nil then
        refuse(notice, complaint)
    end

    if address == nil then
        return nil
    end

    local letter = {
        to = address,
        from = self.from,
        subject = content.subject,
        text = body_of(self, notice, content.text, content.text_view, content.data),
        html = body_of(self, notice, content.html, content.view, content.data),
        headers = { [Module.HEADER] = notice.id },
    }

    if letter.text == nil and letter.html == nil then
        refuse(notice, 'у письма нет тела — дайте text, html, view либо text_view')
    end

    return letter
end

--- Отправляет письмо.
---@param letter table Готовое письмо из очереди
---@return boolean|nil sent
---@return TntStorageFailure|nil err
function Mail:deliver(letter)
    local sent, err = self.mailer.send(letter)

    if sent then
        return true
    end

    local text = 'письмо не отправлено: ' .. tostring(err)

    if text:find(PERMANENT) then
        return nil, failure.new(failure.REJECTED, text)
    end

    return nil, failure.new(failure.BROKEN, text, { idempotent = true })
end

--- Заводит канал писем.
---@param opts { mailer: table, views: table|nil, from: any }
---@return TntNotificationMail
function Module.new(opts)
    local caller = must.at(2)

    caller.options(opts, 'настройки канала писем', OPTIONS)
    caller.callable(opts.mailer.send, 'настройки канала писем.mailer.send')

    return setmetatable({ mailer = opts.mailer, views = opts.views, from = opts.from }, Mail)
end

return Module
