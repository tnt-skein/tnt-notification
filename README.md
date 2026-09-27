# tnt-notification

Уведомления пользователю приложения для Tarantool: «вам ответили»,
«подтвердите почту», «задание выполнено». Адресат — запись модели,
уведомление — объявленный вид с видом для каждого канала, каналы — ящик
на узле с отметкой «прочитано», письмо и вебхук. Всё, кроме ящика, уходит
очередью с повторами, а ящик и сообщения очереди пишутся одной
транзакцией `box`.

```lua
local notification = require('tnt.notification')

notification.migration()(box)   -- спейс ящика; в приложении — шаг миграции

local notices = notification.new({
    inbox = notification.inbox(),
    channels = { mail = notification.mail({ mailer = require('tnt.mail'), views = views }) },
    queue = require('tnt.queue').declare('deliveries', { ttr = 30 }),
})

notices:declare('replied', {
    via = { 'inbox', 'mail' },
    inbox = function(data)
        return { title = 'Вам ответили', thread = data.thread }
    end,
    mail = function(data, user)
        return { subject = 'Вам ответили', view = 'mail.replied', data = { name = user.name } }
    end,
})

local users = notices:recipient({ space = 'users' }, { addresses = { mail = 'email' } })

users:notify(user, 'replied', { thread = 7 })
--> { id = '01K5…', stored = { 'inbox' }, queued = { 'mail' }, skipped = {} }
users:page(user, { unread = true })
--> { items = { { id = '01K5…', kind = 'replied', data = { … }, read = false, … } } }
```

Зависимости: `tnt-must` (проверки аргументов), `tnt-storage` (отказ
`TntStorageFailure`), `tnt-id` (ULID уведомления), `tnt-clock` (стенные
часы отправки и прочтения), `tnt-hash` (подпись вебхука) и `tnt-external`
(подмена часов и опознавателя в проверках). Очередь, почта, шаблоны
и клиент HTTP приходят аргументами: пакет знает их договор, а не их
самих; договор выполняют `tnt-queue`, `tnt-mail`, `tnt-template`
и `tnt-http`.

## Зачем

Сказать что-то пользователю — четыре заботы, и каждая, сделанная по
месту, ломается по-своему: адрес письма лежит в одной записи, адрес
вебхука — в другой, а в ящике пользователь ищется по опознавателю из
сессии; три вида одного уведомления, написанные в трёх обработчиках,
разъезжаются; письмо без очереди теряется с первым отказом почтовика;
непрочитанное и пометки нужны поверх спейса, который не обходит
прочитанное. Пакет делает пять вещей:

- **Адресат — род на модель.** Род — имя спейса модели, адресат —
  опознаватель записи строкой, адрес канала — поле записи либо функция.
- **Вид уведомления — одно объявление.** Каналы (`via`) и вид каждого
  канала объявляются вместе; канал без вида и вид без канала —
  исключение при объявлении, а не молчаливый пропуск.
- **Одна транзакция на всё.** Ящик и сообщения очереди пишутся одной
  транзакцией `box`, а внутри чужой транзакции становятся её частью.
- **Доставка — очередью.** Письмо и вебхук уходят сообщением очереди
  и повторяются ею с отступом; то, что не пройдёт никогда (почтовик
  ответил 550, вебхук — 404), зарывается сразу.
- **Ящик на узле.** Страница новых первыми с курсором, счёт
  непрочитанных по индексу, пометка одного — только своего — и всего
  кусками.

## Установка

```sh
tt rocks install tnt-notification --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-notification.git
cd tnt-notification && tt rocks make
```

## Как пользоваться

| Вызов | Что делает |
|---|---|
| `notification.migration(opts)` | шаг миграции: спейс ящика и три индекса; повторно безопасен |
| `notification.inbox(opts)` | ящик над спейсом; по умолчанию `notifications` |
| `notification.new(opts)` | центр: `inbox`, `channels`, `queue` с методом `send` |
| `notification.mail(opts)` | канал писем: `mailer`, `views`, `from` |
| `notification.webhook(opts)` | канал вебхука: `client`, `url`, `secret`, `headers` |
| `notices:declare(name, spec)` | вид уведомления: `via` и вид каждого канала |
| `notices:recipient(model, opts)` | род адресата: `key`, `addresses` |
| `notices:handler()` | обработчик для `queue:consume` |
| `users:notify(record, kind, data)` | отправка; отчёт `{ id, stored, queued, skipped }` либо `nil, err` |
| `users:page(target, opts)` | страница новых первыми: `limit` (до 100), `after`, `unread` |
| `users:unread(target)` | сколько непрочитанных |
| `users:mark_read(target, id)` | пометить одно; чужое, прочитанное, несуществующее — `false` |
| `users:mark_all_read(target)` | пометить всё кусками по 500; сколько помечено |

Доставку ведёт работник очереди: значение подтверждает сообщение, пара
`nil, err` возвращает его с отсрочкой, `err.retriable == false` зарывает
сразу.

```lua
local consumer = queue:consume(notices:handler(), { workers = 2 })
```

Свой канал — таблица с `prepare` (в файбере отправителя: из вида —
простые данные для очереди, `nil` — канал адресату не нужен) и `deliver`
(в работнике: `true` либо `nil, err`). Отказ — пара `nil, err`
с `TntStorageFailure`; ошибка программиста — исключение на строке
вызывающего:

```lua
users:page(7, { limit = 101 })
--> app.lua:12: настройки страницы.limit — число от 1 до 100, а не 101
```

## Проверки

```sh
make deps          # luatest, luacheck, luacov с cluacov, зависимости пакета, tnt-queue и tnt-template в .rocks
make check         # форматирование, линт, проверки, покрытие с порогом 100 %
make mutants-all   # мутационное тестирование утилитой tnt-mutants из PATH, порог 100 % убитых
```

Покрытие строк — 100 %, убитых мутантов — 100 % (55 проверок, 18 из них —
на узлах; 334 мутанта в пяти модулях). Ящик и транзакция проверяются
на настоящем `box`, доставка — на настоящей очереди `tnt-queue`
с письмом по шаблону `tnt-template`, пережившим перезапуск узла.

## Документ

Полное описание с обоснованием решений: [docs/notification.md](docs/notification.md).

## Лицензия

MIT.
