# Этап 0. Планировка больницы

Справочник по геометрии, которую строит `tools/BuildHospital.lua`.
Все координаты в студах, пол каждой комнаты лежит верхней гранью на `Y = 0`.

## Общие размеры

| Параметр | Значение |
| --- | --- |
| Высота стен | 14 |
| Толщина стен | 1 |
| Высота дверного проёма | 9 |
| Толщина пола и потолка | 1 |
| Ширина коридора | 12 (Z от -6 до 6) |
| Длина коридора | 80 (X от -10 до 70) |

## Комнаты

| Комната | Центр (X, Z) | Размер (X x Z) | Дверь | Ширина проёма | Стену с дверью строит |
| --- | --- | --- | --- | --- | --- |
| Reception | (-22, 0) | 24 x 20 | восточная, X = -10 | 12 | комната |
| BasicMedical (Room 1) | (8, -16) | 24 x 20 | южная, Z = -6 | 10 | коридор |
| XRay (Room 2) | (8, 16) | 24 x 20 | северная, Z = 6 | 10 | коридор |
| HeartMonitor (Room 7) | (44, -16) | 24 x 20 | южная, Z = -6 | 10 | коридор |
| Surgery (Room 8) | (44, 16) | 24 x 20 | северная, Z = 6 | 10 | коридор |
| BreakRoom (магазин) | (82, 0) | 24 x 24 | западная, X = 70 | 12 | комната |

Стена между коридором и кабинетом существует в одном экземпляре: у четырёх
кабинетов её строит коридор вместе с проёмом, чтобы не было двух частей в одной
плоскости. Reception и BreakRoom стоят на торцах коридора и строят свою стену сами.

## Дерево в Workspace

```
Workspace
  Hospital                  Model, атрибут LayoutVersion = 1
    Corridor                Model
      Structure             Folder: Floor, Ceiling, Wall x N, Lintel x N
      EntryPoint            Part
    Rooms                   Folder
      Reception             Model
        Structure           Folder: Floor, Ceiling, Wall, Lintel,
                            ReceptionDesk, ReceptionWindow,
                            ReceptionWindowFrame, PatientSpawn, PlayerSpawn
        EntryPoint          Part
        InteractionZone     Part
        RoomLabel           Part + SurfaceGui "Display" + TextLabel "Text"
      BasicMedical          Model (Structure, EntryPoint, InteractionZone, RoomLabel)
      XRay                  Model (то же)
      HeartMonitor          Model (то же)
      Surgery               Model (то же)
      BreakRoom             Model (то же)
```

## Атрибуты моделей комнат

- `RoomId` - строковый идентификатор, совпадает с именем модели (`BasicMedical`, `XRay`, ...).
- `DisplayName` - человекочитаемое название.
- `RoomNumber` - номер по роадмапу, только у четырёх кабинетов (1, 2, 7, 8).

Этап 1 (`RoomRegistry`) будет опираться на `RoomId`, так что менять имена моделей
без правки реестра нельзя.

## Маркерные части

- `EntryPoint` - 4 x 0.4 x 4, зелёный, `CanCollide = false`. Точка, куда ставится
  пациент при входе в комнату. У кабинетов стоит в 4 студах от двери внутри комнаты,
  у Reception вынесен на сторону посетителя.
- `InteractionZone` - 12 x 8 x 12 (у Reception 8 x 8 x 18 у стойки), полупрозрачный,
  `CanCollide = false`, `CanTouch` и `CanQuery` оставлены включёнными, чтобы этап 1
  мог ловить вход через `Touched` или `GetPartsInPart`.
- `RoomLabel` - табличка над дверью со стороны коридора, текст в
  `RoomLabel.Display.Text`.

## Ресепшн

Стойка стоит по X = -26 и делит комнату надвое: посетитель с запада (X от -34 до -26),
игрок с востока (X от -26 до -10), выход в коридор через восточную дверь.
Стойка перекрывает Z от -8 до 8, по краям остаются проходы шириной 2 студа,
чтобы впущенный пациент мог обойти её и уйти в коридор.

- `PatientSpawn` в точке (-31, 0, 0).
- `PlayerSpawn` (SpawnLocation) в точке (-16, 0.5, 0).
