# Animal Hospital

Roblox-игра по мастер-роадмапу из `docs/roadmap.md`. Собирается поэтапно:
сначала вся больница целиком визуально, затем поочерёдно включаются механики.

## Текущее состояние

Этап 0: каркас больницы. Сцена без игровых скриптов.

## Как собрать сцену (этап 0)

1. Открыть место в Roblox Studio.
2. View -> Command Bar.
3. Вставить целиком содержимое `tools/BuildHospital.lua` и нажать Enter.
4. Сохранить место.

Скрипт идемпотентный: при повторном запуске он удаляет старую `Workspace.Hospital`
и строит её заново. Правки геометрии делаются в таблице `ROOMS` внутри скрипта,
а не руками в Studio, иначе они потеряются при следующей сборке.

Что получается: ресепшн со стойкой и точкой спавна пациента, коридор, четыре
кабинета (Basic Medical / DNA, X-Ray, Heart Monitor, Surgery) и комната отдыха
под будущий магазин. У каждой комнаты одинаковая структура: `Structure`,
`EntryPoint`, `InteractionZone`, `RoomLabel`. Точные координаты и дерево
инстансов описаны в `docs/stage-0-layout.md`.

## Структура репозитория

```
default.project.json   заготовка Rojo 7 под этапы 1+ (пока src пустой)
docs/roadmap.md        мастер-роадмап
docs/stage-0-layout.md планировка и координаты этапа 0
src/shared             ModuleScript'ы в ReplicatedStorage.Shared
src/server             скрипты в ServerScriptService.Server
src/client             скрипты в StarterPlayer.StarterPlayerScripts.Client
tools/BuildHospital.lua сборщик сцены для командной строки Studio
```

## Дальше

Этап 1: `RoomRegistry` - ModuleScript с таблицей комнат и флагом `isImplemented`.
Он будет находить комнаты по атрибуту `RoomId` на моделях в `Workspace.Hospital.Rooms`.
