# Визуал: решения (Opus)

## Машина
- Конвейер: `scripts/build_car.sh` → `pipeline/build_car.py` (Blender 4.5 headless). Превью: `scripts/render_car.sh` (Cycles на RX 7800 XT через HIP).
- Godot: машина = `game/assets/cars/ccgt/ccgt_visual.tscn` (скрипт `scripts/visual/car_visual.gd`). Он подменяет материалы из GLB по имени на шейдеры `game/shaders/*`.
- API для физики: `set_brake(0..1)`, `set_reverse(bool)`, `set_headlights(bool)`, `set_disc_heat(id, 0..1)`, `set_paint(Color)`, `set_dirt(0..1)`, `get_wheel(id)`, `get_caliper(id)`.
- Шейдеры: `car_paint` (хлопья в object space со сглаживанием по footprint, clearcoat, flop), `carbon` (плетение 2x2 twill с анизотропией, UV в метрах), `car_glass` (френель), `car_light` (instance-параметр `lamp`), `brake_disc` (instance-параметр `heat`, накаливание), `tire`.

## Небо и время суток
- HDRI-серия Poly Haven «qwantani»: 12 снимков одного места в течение дня. `pipeline/hdri_sun.py` считает направление, цвет и энергию солнца → `game/assets/hdri/qwantani/sun_data.json`.
- `sky_hdri.gdshader` смешивает два соседних снимка и обрезает солнечный диск HDRI (клэмп 40): прямой свет даёт DirectionalLight, второй раз в окружение он не попадает. Ниже горизонта рисуется цвет земли.
- `scripts/visual/sky_rig.gd` (`SkyRig`): `set_time(h)` и `set_keyframe(name)`. Яркость кадров нормирована таблицей TARGET (полдень = 1), остальное делает автоэкспозиция.

## Витрина
- `scenes/showcase/car_showcase.tscn`: аргументы `--view= --tod= --paint=r,g,b --lights=1 --brake=1 --heat= --steer=`.
