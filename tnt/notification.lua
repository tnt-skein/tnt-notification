--- Уведомления пользователю: адресат, каналы и отметка «прочитано».
---
---     local notification = require('tnt.notification')
---
---     schema.register(12, notification.migration())   -- спейс notifications
---
---     local notices = notification.new({
---         inbox = notification.inbox(),
---         channels = {
---             mail = notification.mail({ mailer = require('tnt.mail'), views = views }),
---             webhook = notification.webhook({ client = client, secret = secret }),
---         },
---         queue = queue.declare('deliveries', { ttr = 30 }),
---     })
---
---     notices:declare('replied', {
---         via = { 'inbox', 'mail' },
---         inbox = function(data) return { title = 'Вам ответили', thread = data.thread } end,
---         mail = function(data, user)
---             return { subject = 'Вам ответили', view = 'mail.replied', data = { name = user.name } }
---         end,
---     })
---
---     local users = notices:recipient(User, { addresses = { mail = 'email' } })
---
---     users:notify(user, 'replied', { thread = 7 })   -- ящик и очередь — одной транзакцией
---     queue:consume(notices:handler(), { workers = 2 })
---
---     users:page(user, { unread = true })             -- новые первыми, курсор next
---     users:mark_read(user, id)
---
--- Адресат — запись модели: род адресата объявляется на модель, адрес
--- канала — поле записи либо функция от неё. Уведомление — объявленный
--- вид с видом для каждого канала. Каналы: `inbox` — ящик на узле, спейс
--- с признаком «прочитано»; `mail` — письмо почтой, пришедшей аргументом;
--- `webhook` — POST на адрес адресата либо общий. Всё, кроме ящика, уходит
--- очередью с повторами, а ящик и сообщения очереди пишутся одной
--- транзакцией box.
---
--- Части: `inbox` — ящик и шаг миграции; `center` — виды, отправка
--- и обработчик очереди; `recipient` — адресат и чтение ящика; `mail`
--- и `webhook` — каналы.
---
--- Подробно — `docs/notification.md`.

local center = require('tnt.notification.center')
local inbox = require('tnt.notification.inbox')
local mail = require('tnt.notification.mail')
local recipient = require('tnt.notification.recipient')
local webhook = require('tnt.notification.webhook')

---@class TntNotification
local Module = {}

Module.center = center
Module.recipient = recipient

--- Центр уведомлений: ящик, каналы и очередь.
Module.new = center.new

--- Ящик на узле: `notification.inbox({ space = 'notifications' })`.
Module.inbox = inbox.new

--- Шаг миграции ящика: `schema.register(n, notification.migration())`.
Module.migration = inbox.migration

--- Канал писем: `notification.mail({ mailer = require('tnt.mail'), views = views })`.
Module.mail = mail.new

--- Канал вебхука: `notification.webhook({ client = client, url = …, secret = … })`.
Module.webhook = webhook.new

return Module
