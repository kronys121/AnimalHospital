# Animal Hospital

Roblox-игра по мастер-роадмапу из `docs/roadmap.md`. Собирается поэтапно:
сначала вся больница целиком визуально, затем поочерёдно включаются механики.

## Текущее состояние

Этап 0: каркас больницы. Сцена без игровых скриптов.

## Как запустить (этап 0)

1. Открыть место в Roblox Studio.
2. В `ServerScriptService` создать `Script` (тип Server).
3. Вставить в него целиком содержимое `src/server/BuildHospital.server.lua`.
4. Нажать Play.

Больше ничего делать не нужно: скрипт сам строит всю больницу при старте сервера.
Старая `Workspace.Hospital` и лишние `SpawnLocation` (в том числе стандартный
с Baseplate) удаляются перед сборкой, так что повторный запуск безопасен.

Больница строится заново на каждом запуске, поэтому править её руками в Studio
бессмысленно: геометрия задаётся таблицей `ROOMS` в начале скрипта.

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
  BuildHospital.server.lua  строит больницу при запуске игры
src/client             скрипты в StarterPlayer.StarterPlayerScripts.Client
```

## Дальше

Этап 1: `RoomRegistry` - ModuleScript с таблицей комнат и флагом `isImplemented`.
Он будет находить комнаты по атрибуту `RoomId` на моделях в `Workspace.Hospital.Rooms`.
