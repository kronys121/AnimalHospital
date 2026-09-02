# Animal Hospital

Roblox-игра по мастер-роадмапу из `docs/roadmap.md`. Собирается поэтапно:
сначала вся больница целиком визуально, затем поочерёдно включаются механики.

## Текущее состояние

Этап 2/3: больница построена (шире, чем раньше), пациенты приходят,
регистрация — физическая (камера → фото → компьютер → принтер → карточка →
вручение, отказ отдельной кнопкой), все четыре кабинета лечат по-настоящему
через автомат с препаратами, вид от первого лица.

## Как запустить

1. Открыть место в Roblox Studio.
2. В `ReplicatedStorage` создать папку `Shared`, в ней два `ModuleScript`:
   - `RoomRegistry` ← `src/shared/RoomRegistry.lua`
   - `PatientData` ← `src/shared/PatientData.lua`
3. В `ServerScriptService` создать:
   - ModuleScript `PickupSystem` ← `src/server/PickupSystem.lua`
   - Script `BuildHospital` ← `src/server/BuildHospital.server.lua`
   - Script `ShiftServer` ← `src/server/ShiftServer.server.lua`
   - Script `TreatmentRooms` ← `src/server/TreatmentRooms.server.lua`
4. В `StarterPlayer` → `StarterPlayerScripts` создать три `LocalScript`:
   - `ReceptionClient` ← `src/client/ReceptionClient.client.lua`
   - `FirstPersonCamera` ← `src/client/FirstPersonCamera.client.lua`
   - `TreatmentHud` ← `src/client/TreatmentHud.client.lua`
5. Нажать Play.

Имена инстансов важны: скрипты находят друг друга по ним. `ShiftServer`
требует `PickupSystem` как соседний инстанс, поэтому оба должны лежать прямо
в `ServerScriptService`, не во вложенных папках. RemoteEvent'ы сервер создаёт
сам, руками их заводить не нужно.

Больше ничего делать не нужно: скрипт сам строит всю больницу при старте сервера.
Старая `Workspace.Hospital` и лишние `SpawnLocation` (в том числе стандартный
с Baseplate) удаляются перед сборкой, так что повторный запуск безопасен.

Больница строится заново на каждом запуске, поэтому править её руками в Studio
бессмысленно: геометрия задаётся таблицей `ROOMS` в начале скрипта.

Здание буквой Т: коридор с кабинетами — перекладина, лобби с ресепшном —
ножка, примыкающая к коридору с юга открытым T-перекрёстком. Пациент
появляется у уличного входа, идёт через лобби со стульями (ресепшн видна
слева), встаёт в очередь к стойке, возвращается в лобби и идёт прямо на
перекрёсток, где кабинеты открываются налево и направо. Четыре кабинета
(Basic Medical / DNA, X-Ray, Heart Monitor, Surgery) и комната отдыха под
будущий магазин — увеличенного размера, чтобы не давить теснотой. У каждой
комнаты одинаковая структура: `Structure`, `EntryPoint`, `InteractionZone`,
`RoomLabel`. Точные координаты и дерево инстансов описаны в
`docs/stage-0-layout.md`.

## Структура репозитория

```
default.project.json   проект Rojo 7 (src маппится в ReplicatedStorage/ServerScriptService)
docs/roadmap.md        мастер-роадмап
docs/stage-0-layout.md планировка и координаты этапа 0
docs/stage-1-room-registry.md  реестр кабинетов, API и подмена заглушек
docs/stage-2-patients.md       пациенты, фотография, цикл регистрации
docs/stage-2b-registration-and-treatment.md  физическая регистрация, автоматы, вид от первого лица
src/shared             ModuleScript'ы в ReplicatedStorage.Shared
  RoomRegistry.lua          реестр лечебных кабинетов
  PatientData.lua           генератор пациентов и правила решения
src/server             скрипты в ServerScriptService.Server
  PickupSystem.lua          взять предмет в руки / положить обратно
  BuildHospital.server.lua  строит больницу при запуске игры
  ShiftServer.server.lua    приход пациентов, физическая регистрация, маршрут в кабинет
  TreatmentRooms.server.lua автомат с препаратами в каждом кабинете
src/client              скрипты в StarterPlayer.StarterPlayerScripts.Client
  ReceptionClient.client.lua  информационная карточка у стойки
  FirstPersonCamera.client.lua  вид от первого лица
  TreatmentHud.client.lua       таймер выбора препарата на экране
```

## RoomRegistry (этап 1)

`src/shared/RoomRegistry.lua` - единственное место, которое знает о лечебных
кабинетах. Четыре кабинета (Basic Medical / DNA, X-Ray, Heart Monitor, Surgery).
Кабинет переключается на мини-игру одним вызовом `setHandler`, остальной код
при этом не меняется. Подробности и API - в `docs/stage-1-room-registry.md`.

## Пациенты и регистрация (этапы 2/3)

Пациент выходит из уличного входа, идёт через лобби к стойке. Регистрация
физическая, не через UI-кнопки: камера на столе делает фото (оно появляется
на столе физическим предметом, можно взять в руки и положить обратно),
компьютер оформляет карточку, принтер её печатает, а вручение карточки
пациенту и есть впуск. Отклонить можно отдельной кнопкой на столе - без
фото и карточки.

Признак «слишком много зубов» виден на фото, а «дёргается» и «неправильный
голос» - нет: они проявляются только вживую у стойки. Примерно половина
аномалий ловится фото, половина требует понаблюдать. Ответы (`isAnomaly`,
признаки, верный препарат) не покидают сервер.

Подробности генератора пациентов - в `docs/stage-2-patients.md`; вся
физическая цепочка регистрации, `PickupSystem` и автоматы с препаратами -
в `docs/stage-2b-registration-and-treatment.md`.

## Лечение

Все четыре кабинета лечат по-настоящему: автомат с тремя препаратами и
15 секунд на выбор (паттерн этапа 5 роадмапа, применённый сразу ко всем
четырём). Дальнейшие этапы 8/11/12 всё ещё могут дать X-Ray, Heart Monitor и
Surgery собственные уникальные мини-игры через `RoomRegistry.setHandler` -
это не отменяется, просто не сделано сейчас.

## Дальше

Этап 4: Sanity 0-100 с полоской в UI, таймер смены на 5 минут, экран
результатов. Сейчас за ошибку нет никаких последствий, кроме разбора в
баннере.
