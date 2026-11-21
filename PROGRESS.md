# DRIVE1: прогресс

## Статус фаз
| Фаза | Статус |
|---|---|
| 0. Инструменты и каркас | выполнена |
| 1. Конвейер модели машины | в работе |
| 2-5 | не начаты |

## Версии инструментов
- Godot **4.7.2-stable** (win64, `tools/godot/Godot_v4.7.2-stable_win64_console.exe`). Terrain3D v1.1.0 (2026-10-30) поддерживает Godot 4.5-4.8+, значит 4.7.2 (последняя стабильная на момент выбора) совместима. Terrain3D ставится в фазе 3.
- Blender **4.5.16 LTS** (portable zip, `tools/blender/blender.exe`). Версия 4.5 выбрана как последняя 4.x (есть 5.x, но 4.5 LTS стабильнее по Python API).
- GPU в логе Godot: `Vulkan 1.4.349 - Forward+ - Using Device #0: AMD - AMD Radeon RX 7800 XT` (индекс 0, `--gpu-index 0` добавляется автоматически скриптом `scripts/godot.sh`).

## Решения
- Проект Godot лежит в `game/`; Forward+, Jolt Physics, 240 тиков физики, max_physics_steps_per_frame = 8, окно 1920x1080, vsync включён.
- `scripts/godot.sh` добавляет `--language en` (стабильные английские логи; системная локаль русская) и вырезает ANSI-коды.
- Тесты: `scripts/test.sh [префикс]` запускает `game/tests/*_tests.gd` через `tests/test_runner.gd` (SceneTree-скрипт), exit code 1 при провале теста или ошибке движка в логе.
- Скриншоты: `scripts/shot.sh <сцена> <out.png> [кадров] [WxH]` через Movie Maker, сохраняется последний кадр.
- `koenigsegg-ccgt.zip` и `tools/` в `.gitignore`; `assets_raw/` (распакованные OBJ) коммитятся как исходник.

## Известные проблемы
- (пока нет)
