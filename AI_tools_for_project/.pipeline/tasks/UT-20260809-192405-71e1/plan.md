# Розовое оформление основной формы реализации — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Придать розовое оформление контейнерам основной формы документа «Реализация товаров и услуг» в основной конфигурации, не меняя поведение и структуру формы.

**Architecture:** Изменение ограничено семью статическими свойствами `BackColor` в одном `Form.xml`: четыре светлых фона страниц и три более насыщенных фона крупных полос формы. Модуль формы, элементы стиля, метаданные документа, другие формы и расширения не меняются; существующие семантические цвета сохраняются.

**Tech Stack:** XML-исходники 1С UT 11.5.19.74, управляемая форма XCF `version="2.21"`, платформа `C:\Program Files\1cv8\8.5.1.1302\bin`, PowerShell, навыки `form-info` и `form-validate`, Git.

## Global Constraints

- Целевая конфигурация — основная конфигурация, без расширения.
- Единственный изменяемый продуктовый файл: `Documents/РеализацияТоваровУслуг/Forms/ФормаДокумента/Ext/Form.xml`.
- `Documents/РеализацияТоваровУслуг.xml:239` должно по-прежнему задавать `DefaultObjectForm` как `Document.РеализацияТоваровУслуг.Form.ФормаДокумента`.
- Не менять `Documents/РеализацияТоваровУслуг/Forms/ФормаДокумента/Ext/Module.bsl`, `Documents/РеализацияТоваровУслуг/Forms/ФормаДокумента.xml`, метаданные документа, другие формы, StyleItems и расширения.
- Не менять существующие `BackColor` `style:ЦветФонаВыделения` и `style:ИтогиФон` и не перекрашивать поля, таблицы или семантические уведомления.
- Work не загружает XML в файловую базу, не обновляет конфигурацию БД и не запускает 1С; это допускается только Deploy после dry-run и валидного approval, связанного с неизменным SHA-256 сценария.
- Сохранять существующие GUID/ID, порядок элементов, команды, обработчики, свойства доступности/видимости, UTF-8 BOM и имеющийся профиль переводов строк.
- Не затрагивать уже существующие несвязанные изменения рабочей копии.

---

## Design Decision

Выбран статический фон крупных контейнеров в целевом `Form.xml`:

| Тип | Элемент | Цвет |
| --- | --- | --- |
| `Page` | `ГруппаОсновное` | `#FFF0F5` |
| `Page` | `ГруппаТовары` | `#FFF0F5` |
| `Page` | `СтраницаДоставка` | `#FFF0F5` |
| `Page` | `ГруппаДополнительно` | `#FFF0F5` |
| `UsualGroup` | `ГруппаСтатус` | `#F8BBD0` |
| `UsualGroup` | `ГруппаПодвал` | `#F8BBD0` |
| `UsualGroup` | `ГруппаСчетФактураИСостояние` | `#F8BBD0` |

Программная окраска отклонена, потому что потребовала бы изменения `Module.bsl` и добавила поведенческий код. Общие StyleItems отклонены как выход за пределы одной формы. Окраска кнопки «Провести и закрыть» исключена после проверки контраста и из-за зависимости её рендеринга от интерфейса платформы.

Прямой прецедент `BackColor` у `Page` находится в `DataProcessors/ГрупповаяОбработкаРаспознанныхДокументов/Forms/ГрупповаяОбработка/Ext/Form.xml` на страницах `ГруппаПолеПросмотра0` и `ГруппаПолеПросмотра1`; локальный schema-profile `.codex/skills/form-compile/scripts/form-compile.ps1` также эмитит оформление `Page` перед companion-элементом.

## Acceptance Scenarios

1. **Новый документ:** после отдельного Deploy открыть новую реализацию; контейнеры вкладок «Основное», «Товары», «Доставка», «Дополнительно» имеют светло-розовый фон в свободных областях, а полосы статуса и нижней части — более насыщенный розовый фон.
2. **Существующий документ:** открыть ранее записанную реализацию; значения, видимость, доступность, команды, навигация по вкладкам, запись и проведение работают как до изменения.
3. **Семантические цвета:** на вкладке «Основное» проверить область с `style:ЦветФонаВыделения`, в подвале — группу итогов с `style:ИтогиФон`; они различимы и не заменены розовой палитрой.
4. **Системные части интерфейса:** корешки вкладок `TabsOnTop`, поля и таблицы могут сохранять системные цвета; приёмка относится к фону контейнеров, а не к полной перекраске каждого контрола.
5. **Негативный сценарий Deploy:** если платформа отвергает XML, обновление конфигурации БД не завершается или визуальная проверка выявляет нечитаемый/полосатый результат, Deploy прекращает сценарий и восстанавливает базу из созданной перед загрузкой резервной копии согласно одобренному сценарию.

### Task 1: Точечное оформление формы и статическая верификация

**Files:**

- Modify: `Documents/РеализацияТоваровУслуг/Forms/ФормаДокумента/Ext/Form.xml`
- Inspect only: `Documents/РеализацияТоваровУслуг.xml`
- Inspect only: `Documents/РеализацияТоваровУслуг/Forms/ФормаДокумента/Ext/Module.bsl`

**Interfaces:**

- Consumes: существующие `Page` и `UsualGroup`, найденные по точным `name`; никаких новых ID, реквизитов, команд или обработчиков.
- Produces: семь собственных дочерних `BackColor` со значениями из таблицы Design Decision; все остальные XML-узлы побайтно/структурно эквивалентны базовой версии.

- [ ] **Step 1: Зафиксировать исходную структуру и выполнить отрицательную проверку палитры**

Run:

```powershell
$formPath = 'Documents\РеализацияТоваровУслуг\Forms\ФормаДокумента\Ext\Form.xml'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.codex\skills\form-info\scripts\form-info.ps1' -FormPath $formPath -Limit 250
Select-String -Path 'Documents\РеализацияТоваровУслуг.xml' -Pattern '<DefaultObjectForm>Document.РеализацияТоваровУслуг.Form.ФормаДокумента</DefaultObjectForm>'

[xml]$xml = [IO.File]::ReadAllText((Resolve-Path $formPath), [Text.Encoding]::UTF8)
$targets = @(
    @{ Type = 'Page'; Name = 'ГруппаОсновное' },
    @{ Type = 'Page'; Name = 'ГруппаТовары' },
    @{ Type = 'Page'; Name = 'СтраницаДоставка' },
    @{ Type = 'Page'; Name = 'ГруппаДополнительно' },
    @{ Type = 'UsualGroup'; Name = 'ГруппаСтатус' },
    @{ Type = 'UsualGroup'; Name = 'ГруппаПодвал' },
    @{ Type = 'UsualGroup'; Name = 'ГруппаСчетФактураИСостояние' }
)
foreach ($target in $targets) {
    $node = $xml.SelectSingleNode("//*[local-name()='$($target.Type)' and @name='$($target.Name)']")
    if ($null -eq $node) { throw "Не найден $($target.Type) $($target.Name)" }
    if (@($node.SelectNodes("./*[local-name()='BackColor']")).Count -ne 0) {
        throw "Исходный элемент уже содержит BackColor: $($target.Name)"
    }
}
throw 'RED: семь ожидаемых BackColor ещё отсутствуют'
```

Expected: `form-info` распознаёт `ФормаДокумента (Documents.РеализацияТоваровУслуг)`; `DefaultObjectForm` найден; каждый целевой элемент существует с ожидаемым типом и без собственного `BackColor`; последняя команда намеренно завершается сообщением `RED`.

Baseline byte profile for later comparison: UTF-8 BOM `EF-BB-BF`, `6613` CRLF, `21` bare LF, no bare CR. Existing own form colors count: `2` (`style:ЦветФонаВыделения`, `style:ИтогиФон`).

- [ ] **Step 2: Добавить семь свойств с XSD-совместимым порядком**

Использовать `apply_patch`; не переписывать XML сериализатором.

Для каждой из четырёх страниц вставить одну строку

```xml
<BackColor>#FFF0F5</BackColor>
```

после `Group`/`TitleDataPath`/`ShowTitle` конкретной страницы и строго перед `ScrollOnCompress` либо `ExtendedTooltip` — то есть в позиции оформления, предшествующей layout-tail/companion в сериализованном профиле этой формы.

Для `ГруппаСтатус`, `ГруппаПодвал` и `ГруппаСчетФактураИСостояние` вставить одну строку

```xml
<BackColor>#F8BBD0</BackColor>
```

после `ShowTitle` и строго перед `ExtendedTooltip`, как у существующей `ГруппаИтого` в этом же файле. Сохранить табуляцию соседних свойств и CRLF каждой добавленной строки.

Expected: добавлено ровно семь строк; существующие строки не изменены и не удалены.

- [ ] **Step 3: Выполнить положительную XML-проверку и доказать отсутствие иных структурных изменений**

Run:

```powershell
$gitPath = 'Documents/РеализацияТоваровУслуг/Forms/ФормаДокумента/Ext/Form.xml'
$formPath = $gitPath.Replace('/', '\')
$expected = [ordered]@{
    'Page|ГруппаОсновное' = '#FFF0F5'
    'Page|ГруппаТовары' = '#FFF0F5'
    'Page|СтраницаДоставка' = '#FFF0F5'
    'Page|ГруппаДополнительно' = '#FFF0F5'
    'UsualGroup|ГруппаСтатус' = '#F8BBD0'
    'UsualGroup|ГруппаПодвал' = '#F8BBD0'
    'UsualGroup|ГруппаСчетФактураИСостояние' = '#F8BBD0'
}

[xml]$actual = [IO.File]::ReadAllText((Resolve-Path $formPath), [Text.Encoding]::UTF8)
foreach ($entry in $expected.GetEnumerator()) {
    $parts = $entry.Key.Split('|')
    $nodes = @($actual.SelectNodes("//*[local-name()='$($parts[0])' and @name='$($parts[1])']"))
    if ($nodes.Count -ne 1) { throw "Ожидался один $($entry.Key), найдено $($nodes.Count)" }
    $colors = @($nodes[0].SelectNodes("./*[local-name()='BackColor']"))
    if ($colors.Count -ne 1 -or $colors[0].InnerText -ne $entry.Value) {
        throw "Неверный BackColor: $($entry.Key)"
    }
}

$baselineText = (git show "HEAD:$gitPath") -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Не удалось прочитать базовый Form.xml из HEAD' }
[xml]$baseline = $baselineText
[xml]$normalizedActual = $actual.OuterXml
foreach ($entry in $expected.GetEnumerator()) {
    $parts = $entry.Key.Split('|')
    $node = $normalizedActual.SelectSingleNode("//*[local-name()='$($parts[0])' and @name='$($parts[1])']")
    [void]$node.RemoveChild($node.SelectSingleNode("./*[local-name()='BackColor']"))
}
if ($normalizedActual.OuterXml -ne $baseline.OuterXml) {
    throw 'После удаления семи разрешённых BackColor структура отличается от HEAD'
}
```

Expected: все семь элементов и цветов найдены в единственном экземпляре; после удаления разрешённых узлов XML структурно совпадает с `HEAD`.

- [ ] **Step 4: Выполнить профильную валидацию формы**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.codex\skills\form-validate\scripts\form-validate.ps1' -FormPath 'Documents\РеализацияТоваровУслуг\Forms\ФормаДокумента\Ext\Form.xml' -Detailed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.codex\skills\form-info\scripts\form-info.ps1' -FormPath 'Documents\РеализацияТоваровУслуг\Forms\ФормаДокумента\Ext\Form.xml' -Limit 250
```

Expected: `form-validate` returns exit code `0`; `form-info` по-прежнему показывает ту же форму, события, атрибуты и команды. Структурное равенство из Step 3 является строгой проверкой, что набор ID, элементов, атрибутов, команд и обработчиков не изменился.

- [ ] **Step 5: Проверить минимальность diff и сохранность файла**

Run:

```powershell
$formPath = 'Documents\РеализацияТоваровУслуг\Forms\ФормаДокумента\Ext\Form.xml'
git diff --check -- $formPath
git diff --name-only -- Documents
git diff --numstat -- $formPath

$bytes = [IO.File]::ReadAllBytes((Resolve-Path $formPath))
if ([BitConverter]::ToString($bytes[0..2]) -ne 'EF-BB-BF') { throw 'UTF-8 BOM изменён' }
$text = [Text.Encoding]::UTF8.GetString($bytes)
$crlf = ([regex]::Matches($text, "`r`n")).Count
$bareLf = ([regex]::Matches($text, "(?<!`r)`n")).Count
$bareCr = ([regex]::Matches($text, "`r(?!`n)")).Count
if ($crlf -ne 6620 -or $bareLf -ne 21 -or $bareCr -ne 0) {
    throw "Профиль переводов строк изменён: CRLF=$crlf bareLF=$bareLf bareCR=$bareCr"
}
```

Expected: `git diff --name-only -- Documents` выводит только целевой `Form.xml`; `git diff --numstat` выводит `7  0` для него; BOM сохранён, CRLF увеличился ровно на семь, исходные `21` bare LF не изменились.

- [ ] **Step 6: Закоммитить реализацию и проверки**

Run:

```powershell
git add -- 'Documents/РеализацияТоваровУслуг/Forms/ФормаДокумента/Ext/Form.xml'
git diff --cached --check
git diff --cached --name-only
git commit -m 'style: оформить форму реализации в розовой гамме'
```

Expected: staged diff содержит только целевой `Form.xml` и семь добавлений; несвязанные изменения остаются незатронутыми.

## Deploy Gate and Visual Acceptance

Work после коммита возвращает Manager хеш реализации и результаты Steps 3–5. До любого изменения файловой базы Deploy обязан:

1. Подготовить dry-run сценарий в `.pipeline/tasks/UT-20260809-192405-71e1/deploy-scenario.md`, привязанный к точному хешу реализации, базе `C:\dev\bases1c\ut11_8_5` и платформе из `.v8-project.json`.
2. Включить в сценарий резервную копию базы, `db-load-git`, `db-update`, запуск клиента только для визуальной проверки Acceptance Scenarios 1–4 и восстановление резервной копии при сценарии 5.
3. Передать сценарий Manager; запись разрешена только после human approval, SHA-256 которого совпадает с неизменным сценарием.
4. После одобрения сначала создать резервную копию, затем загрузить точный Work commit и обновить конфигурацию БД; при любой ошибке прекратить проверку и выполнить только предусмотренное одобренным сценарием восстановление.
5. Зафиксировать фактический рендеринг свободных областей четырёх страниц, обеих нижних полос, семантических цветов, а также запись и проведение нового и существующего документа.

## Acceptance Criteria

- В исходниках основной формы ровно семь целевых `BackColor` с указанными значениями; у остальных элементов оформление не меняется.
- После исключения семи новых узлов XML структурно равен версии `HEAD`; diff содержит `7` добавлений и `0` удалений только в целевом продуктовом файле.
- `DefaultObjectForm`, модуль формы, ID, элементы, реквизиты, команды, обработчики, видимость и доступность сохранены.
- `form-validate` завершается успешно; Work не загружает изменения в базу.
- После отдельного одобренного Deploy фон контейнеров четырёх вкладок заметно светло-розовый, верхняя/нижние полосы — розовые; системные фоны контролов и корешков вкладок не считаются дефектом.
- Выделение и итоги остаются различимыми; запись и проведение работают без регрессий.
- Известный долг принят: форма снята с поддержки, поэтому последующее обновление типовой конфигурации может потребовать ручного повторного применения или разрешения конфликта этих семи строк.

## Opus Reconciliation

Полный ответ: `.pipeline/tasks/UT-20260809-192405-71e1/opus-plan-review.json.stdout.jsonl`; receipt: `.pipeline/tasks/UT-20260809-192405-71e1/opus-plan-review.json` (`status=succeeded`, зарегистрированная session `32aaea71-de6b-4a82-a2af-740b042871ec`).

| Point | Decision | Rationale |
| --- | --- | --- |
| A1 — целевой файл и семь контейнеров существуют | accepted | Подтверждено `form-info` и прямым XML-анализом; точные типы и имена включены в тест. |
| A2 — кнопка существует явно | accepted | Факт подтверждён, но кнопка исключена из окончательного объёма по C6/R3. |
| A3 — целевые элементы не конфликтуют с семантическими цветами | accepted | Существующие цвета вложены в другие элементы и защищены структурным сравнением. |
| A4 — арифметика исходных девяти свойств | accepted | Для исходного draft верно; после исключения кнопки окончательный diff — семь свойств. |
| A5 — прецеденты группы и кнопки | accepted | Групповой прецедент используется для порядка; кнопочный больше не нужен. |
| C1 — задать XSD-совместимые позиции | accepted | Для `UsualGroup` задано `ShowTitle -> BackColor -> ExtendedTooltip`; для `Page` — до `ScrollOnCompress`/`ExtendedTooltip`; schema-profile и репозиторный прецедент указаны. Неопределённость кнопки устранена исключением кнопки. |
| C2 — прецедент `BackColor` у `Page` якобы отсутствует | rejected | Прямые `Page`-прецеденты `ГруппаПолеПросмотра0/1` с `BackColor=#FEFEFE` найдены в `DataProcessors/ГрупповаяОбработкаРаспознанныхДокументов/Forms/ГрупповаяОбработка/Ext/Form.xml`; локальный `form-compile` также явно поддерживает оформление `Page`. |
| C3 — усилить diff и байтовые проверки | accepted | Добавлены точные `name-only`, `numstat=7/0`, BOM и счётчики CRLF/bare LF/bare CR. |
| C4 — baseline должен проверять тип и отсутствие собственного цвета | accepted | Отрицательный тест проверяет все семь имён, точные XML-типы и нулевой собственный `BackColor`. |
| C5 — доказать загружаемость на Deploy | accepted | Добавлен отдельный approval-bound сценарий backup → `db-load-git` → `db-update` → визуальная проверка → предусмотренное восстановление; Work по-прежнему не пишет в БД. |
| C6 — недостаточный контраст кнопки | accepted | Кнопка и `TextColor` полностью исключены, поэтому проблема контраста исчезает без расширения задачи. |
| C7 — сравнить структуру до/после | accepted | Вместо слабого сравнения сводок добавлено более строгое XML-равенство с `HEAD` после удаления семи разрешённых узлов; `form-info` дополнительно выполняется после правки. |
| R1 — розовый виден в свободных областях | accepted | Критерий уточнён: окрашиваются контейнеры, а не собственные фоны таблиц/полей. |
| R2 — корешки вкладок системные | accepted | Явно исключено из дефектов визуальной приёмки. |
| R3 — кнопочный цвет зависит от клиента | accepted | Риск устранён исключением оформления кнопки. |
| R4 — различимость семантических цветов | accepted | Добавлен отдельный ручной сценарий для выделения и итогов. |
| R5 — долг снятой с поддержки формы | accepted | Зафиксирован в Acceptance Criteria как известный долг обновления. |
| R6 — возможная полосатость нижней части | accepted | Включено в визуальную проверку и негативный Deploy-сценарий с восстановлением. |
