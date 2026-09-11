# Murmator: доставка моделей и платные пакеты

Проверено 8 сентября 2026 года по текущему коду и официальным материалам Apple. Изменение доставки и покупок в этой задаче не внедрялось.

## Рекомендация

Для текущего приложения с минимумом iOS 18.0 оставить небольшую базовую сборку и загружать выбранные модели по требованию. На iOS 26+ целевой вариант — Apple‑Hosted Background Assets; для старых поддерживаемых ОС нужен существующий сетевой путь или отдельно поддерживаемый unmanaged Background Assets. Не переводить весь продукт на старые ODR/SKDownload.

Покупка Pro или языкового набора — отдельный слой прав через StoreKit. Файлы могут доставляться с Apple или нашего CDN независимо от способа оплаты. «Аддон» не обязан быть отдельным приложением в App Store.

## Размеры текущего каталога

По закреплённым SHA-256 и размерам файлов 52 пакета перевода суммарно содержат **10,42 ГБ**. Если считать одинаковые файлы по SHA только один раз — **8,74 ГБ**: есть потенциал убрать около 1,68 ГБ повторов. Это логические размеры текущих файлов, не размер сжатых Apple asset packs и не расход RAM. Веса распознавания речи сюда не включены.

Отдельный пакет перевода — примерно 78–253 МБ. Текущая локальная Release `.app` занимает около 77 МиБ по `du`; размер загрузки из App Store будет другим после упаковки/thinning. Все переводческие модели в основной bundle не помещаются в обычный лимит iOS приложения 4 ГБ. [Лимиты приложения](https://developer.apple.com/help/app-store-connect/reference/app-uploads/maximum-build-file-sizes).

## Сравнение

| Способ | Преимущества | Ограничения | Решение для Murmator |
| --- | --- | --- | --- |
| Встроить модели в основной app bundle | Работают сразу, доступны без отдельной загрузки; простой тест расширения. | Рост установки и обновлений; новые веса требуют новой сборки; все 10,42 ГБ не подходят. | Использовать для маленьких обязательных ресурсов или специально выбранного стартового пакета. Одна bundled RU→FI используется в диагностическом прототипе, это не выбранная схема коммерческой доставки. |
| HTTPS с нашего CDN/текущего зеркала | Поддерживает наш минимум ОС, полный контроль версий и обновлений; уже есть рабочий downloader. | Нужны эксплуатация хостинга, контроль трафика, фоновые загрузки/возобновление и обработка ошибок. | Сохранить как текущий путь и совместимость со старыми ОС. Для коммерческого выпуска определить стабильный хостинг и политику обновлений. |
| Unmanaged Background Assets | Фоновая подготовка ресурсов с собственного сервера; базовый API доступен начиная с iOS 16.1 по установленному SDK. | Собственные manifest, планирование, downloader extension и обработка жизненного цикла. | Вариант для ускорения первого старта при сохранении iOS 18, если простой background URLSession недостаточен. |
| Managed + Apple‑Hosted Background Assets | Apple управляет загрузкой/обновлениями/сжатием; веса можно выпускать отдельно от app build; поддерживаются ML-модели. | Managed API требует iOS/iPadOS 26+; поставка через TestFlight/App Store и отдельный downloader extension; нужны App Store Connect и review. | Предпочтительный современный путь для 26+, после проверки прототипа и модели поддержки старых ОС. |
| On-Demand Resources | Исторический способ Apple-hosted ресурсов вне основного bundle. | Apple помечает deprecated с iOS/iPadOS/tvOS 27 и рекомендует Background Assets. | Не выбирать для нового слоя доставки. |
| Старый In-App Purchase Hosted Content / SKDownload | Исторически связывал загрузку контента с покупкой. | SKDownload и связанная функциональность deprecated; документация оставлена для существующих приложений. | Не начинать новую реализацию на нём. |

Источники: [Background Assets](https://developer.apple.com/documentation/backgroundassets), [Unmanaged configuration](https://developer.apple.com/documentation/backgroundassets/configuring-an-unmanaged-background-assets-project), [Apple hosting overview](https://developer.apple.com/help/app-store-connect/manage-asset-packs/overview-of-apple-hosted-asset-packs), [ODR status](https://developer.apple.com/help/app-store-connect/reference/app-uploads/on-demand-resources-size-limits), [legacy hosted purchases](https://developer.apple.com/documentation/storekit/unlocking-purchased-content).

## Как устроены современные пакеты Apple

Apple‑Hosted Background Assets поддерживает ML-модели и поставку через TestFlight/App Store. Для Managed используются политики `essential` (часть установки), `prefetch` (может продолжаться после установки) и `onDemand` (явный запрос из приложения). Для большинства языков Murmator подходит onDemand. Не помечать весь каталог essential. [Apple-hosted downloads](https://developer.apple.com/documentation/backgroundassets/downloading-apple-hosted-asset-packs), [создание пакетов](https://developer.apple.com/documentation/backgroundassets/creating-managed-asset-packs).

Лимит Apple-hosted каталога — **200 ГБ и 200 asset packs** на app record, общий для платформ. Размер считается по максимальной подходящей версии каждого пакета, а не просто по самой новой. Обновления asset packs имеют собственную обработку и review. [Лимиты](https://developer.apple.com/help/app-store-connect/reference/app-uploads/apple-hosted-asset-pack-size-limits), [API управления](https://developer.apple.com/documentation/appstoreconnectapi/background-assets).

App и downloader extension разделяют App Group; настройка использует `BAAppGroupID`, `BAHasManagedAssetPacks`, `BAUsesAppleHosting`. Это не готовое автоматическое подключение нашего TranslationUIProvider: доступ к нужным файлам из него всё равно нужно проверить. Содержимое managed pack следует получать через API менеджера; не строить код на предполагаемом постоянном пути системного кэша. [Настройка загрузчика](https://developer.apple.com/documentation/backgroundassets/downloading-apple-hosted-asset-packs), [BAAppGroupID](https://developer.apple.com/documentation/bundleresources/information-property-list/baappgroupid).

## Предлагаемая структура для нашего кода

1. Единый каталог: `model ID`, версия/совместимость движка, направление или группа языков, размер, SHA-256, лицензия и список файлов. Оплата и наличие файла — разные поля.
2. Источник ресурсов скрыть за одним интерфейсом: текущая HTTPS-загрузка, Apple asset pack либо bundled resource. Движку передавать проверенный локальный каталог.
3. Общие веса хранить один раз, токенизаторы/целевые теги учитывать отдельно. Одинаковый SHA не должен скачиваться повторно для близких направлений.
4. Публикация новой версии целиком и атомарно. Расширение только читает готовую версию; не видит недокачанные файлы. Обновление и удаление координируются с читателями.
5. Для TranslationUIProvider сначала проверить RAM на одной модели, как просил пользователь. Bundling, CDN или Apple hosting меняют доставку, но не устраняют расход памяти при загрузке модели в процесс.
6. Перед большой загрузкой показывать размер, выбор сети и отмену; после неё — фактический статус. При ошибке или отсутствии места не оставлять модель «готовой» по одному файлу model.bin.
7. Отдельный менеджер места: размер установленных пакетов, удаление файлов, повторная загрузка. Сейчас удаление записи из LanguageLibrary меняет только список выбранных языков.
8. Для постоянно доступного офлайн-сценария проверить удержание/повторное получение managed assets при очистке системой и при обновлениях. Наличие права покупки не гарантирует, что файлы уже находятся на устройстве.

Это предлагаемая архитектура. Текущий downloader уже проверяет закреплённые хеши, использует staging и объединяет часть параллельных запросов; межпроцессный слой пакетов ещё предстоит реализовать.

## Что продавать и как доставлять «аддоны»

Обычная App Store схема: StoreKit разблокирует функции/пакеты после проверки транзакций. Non-consumable подходит для бессрочного Pro или отдельного набора; subscription — для доступа на срок и регулярно обновляемого сервиса. Покупки не создаются в этой задаче. [Типы IAP](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-types).

Не использовать наличие файла как доказательство покупки и не доверять одному редактируемому флагу UserDefaults. В StoreKit доступны проверенные текущие entitlements и события обновления/отзыва. [Transaction](https://developer.apple.com/documentation/storekit/transaction), [currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements).

Для стандартной схемы цифровых функций внутри App Store использовать IAP. Региональные варианты внешних покупок требуют отдельного решения; они не нужны для первого обычного Pro. Продажа и маркетинг должны быть в основном приложении: App Review 4.4 не разрешает marketing, advertising или IAP внутри extensions. [App Review Guidelines, 3.1.1 и 4.4](https://developer.apple.com/app-store/review/guidelines/).

Модели имеют разные исходные лицензии. Сохранять атрибуцию и условия конкретных пакетов при коммерческой поставке; не называть весь каталог одним типом лицензии. Список уже зафиксирован в каталоге проекта.

## Практический выбор

- **Сейчас:** небольшая app, скачивание выбранных языков, общая проверяемая модель пакетов. Существующее зеркало не менять в рамках исследования без отдельной миграции.
- **Для App Store на iOS 26+:** проверить Apple‑Hosted Managed Background Assets как основной источник, с onDemand политикой для языков.
- **Для iOS 18.x:** поддерживать HTTPS/собственный CDN; при необходимости отдельно добавить unmanaged Background Assets.
- **Монетизация:** сначала выбрать пользовательские функции и наборы, затем StoreKit; не делать способ доставки частью платного обещания пользователю.
