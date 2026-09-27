rockspec_format = '3.0'

package = 'tnt-notification'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-notification.git',
    branch = 'main',
}

description = {
    summary = 'Уведомления пользователю: адресат, каналы, ящик с отметкой «прочитано», отправка очередью',
    detailed = [[
        Адресат — запись модели: род адресата объявляется на модель,
        опознаватель записи идёт строкой, адрес канала — поле записи либо
        функция от неё. Уведомление — объявленный вид с видом для каждого
        канала: что положить в ящик, какое письмо собрать, какое тело
        отправить вебхуку.

        Каналы: inbox — ящик на узле, спейс с признаком «прочитано»,
        страница новых первыми с курсором, счёт непрочитанных, пометка
        одного и всего; mail — письмо почтой, пришедшей аргументом,
        с телом по шаблону tnt-template; webhook — POST с телом JSON
        и подписью HMAC-SHA256 на адрес адресата либо общий. Свой канал —
        таблица с prepare и deliver.

        Всё, кроме ящика, уходит очередью с методом send — например,
        tnt-queue — и повторяется ею с отступом; ящик и сообщения очереди
        пишутся одной транзакцией box, а внутри чужой транзакции становятся
        её частью. Обработчик для очереди — notices:handler().

        Отказ — пара nil, err с TntStorageFailure; ошибка программиста —
        исключение на строке вызывающего.

        Зависит от tnt-must (проверки аргументов), tnt-storage (отказ),
        tnt-id (ULID уведомления), tnt-clock (стенные часы), tnt-hash
        (подпись вебхука) и tnt-external (подмена часов и опознавателя
        в проверках). Покрытие строк и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-notification',
    issues_url = 'https://github.com/tnt-skein/tnt-notification/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'notifications', 'inbox', 'mail', 'webhook', 'queue' },
}

dependencies = {
    'lua >= 5.1',
    -- Проверки аргументов, настроек и видов на строке вызывающего.
    'tnt-must',
    -- Отказ TntStorageFailure: род и `retriable` решают, повторит ли очередь доставку.
    'tnt-storage',
    -- ULID уведомления: время в старших знаках — порядок ящика по нему.
    'tnt-id',
    -- Стенные часы отправки и прочтения.
    'tnt-clock',
    -- Подпись тела вебхука HMAC-SHA256.
    'tnt-hash',
    -- Подмена часов и опознавателя в проверках.
    'tnt-external',
}

-- Проверкам нужны настоящая очередь и настоящие шаблоны: отправка,
-- пережившая перезапуск узла, и письмо по шаблону сверяются на них,
-- а пакету они приходят аргументом.
test_dependencies = {
    'tnt-queue',
    'tnt-template',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.notification'] = 'tnt/notification.lua',
        ['tnt.notification.center'] = 'tnt/notification/center.lua',
        ['tnt.notification.inbox'] = 'tnt/notification/inbox.lua',
        ['tnt.notification.mail'] = 'tnt/notification/mail.lua',
        ['tnt.notification.recipient'] = 'tnt/notification/recipient.lua',
        ['tnt.notification.webhook'] = 'tnt/notification/webhook.lua',
    },
}
