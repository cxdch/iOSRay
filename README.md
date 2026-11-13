# iOSRay

x-ray engine for iOS — порт OpenXRay на iOS 15+ с Metal. Первый шаг — пробное приложение **XRProbe**.

Первый шаг порта S.T.A.L.K.E.R.: Тень Чернобыля на iOS 15+ (Metal) на базе [OpenXRay](https://github.com/OpenXRay/xray-16).
Файлов игры здесь нет и не будет: репозиторий содержит только код.

XRProbe — пробное приложение, которое проверяет на настоящем iPhone то, что без Mac больше нигде не проверить:

| Проверка | Что показывает |
| --- | --- |
| Нативный хост | UIScene + CAMetalLayer + CADisplayLink, альбомная ориентация, пауза в фоне |
| Metal | Вращающийся треугольник, шейдер компилируется на устройстве |
| Шейдеры OpenXRay | 279 MSL-файлов, полученных из GL-шейдеров движка (GLSL → SPIR-V → MSL), компилируются драйвером Metal телефона; ошибки — в логе |
| Память | Кнопка «Тест памяти»: сколько реально можно занять до jetsam. Сравните SideStore- и TrollStore-сборки |
| GPU | Семейства Apple GPU, поддержка BC (DXT) — от неё зависит, нужна ли перекодировка текстур в ASTC |

Лог: `Documents/xrprobe.log` (виден в «Файлах» → «На iPhone» → XRProbe) или кнопка «Поделиться логом».

## Установка

- **iPhone 14 (iOS 27)** — `XRProbe-sidestore.ipa` через SideStore.
- **iPhone 7 Plus (iOS 15.8.8)** — `XRProbe-trollstore.tipa` через TrollStore. Сборка с правами
  `increased-memory-limit` и `extended-virtual-addressing`.

Для сравнения памяти поставьте на 7 Plus обе сборки по очереди (у них один bundle id).

## Сборка

### В облаке (основной путь, Mac не нужен)

1. Создайте **публичный** репозиторий на GitHub (для публичных macOS-раннеры бесплатны) и загрузите эти файлы.
2. Push в `main` запускает `.github/workflows/build.yml`: конвертация шейдеров → сборка → релиз `nightly`.
3. На iPhone откройте Releases → nightly и скачайте IPA/TIPA.

### На Linux (проверка кода без Mac)

```sh
# нужны clang, lld, zip, ldid (github.com/ProcursusTeam/ldid), glslang, spirv-cross, iPhoneOS SDK
python3 -I scripts/convert_shaders.py <xray-16>/res/gamedata/shaders/gl shaders-out glslangValidator spirv-cross
SDKROOT=/path/iPhoneOS16.5.sdk CXX=clang++ LDFLAGS="-fuse-ld=lld" bash scripts/build_ipa.sh shaders-out/high
```

Релизы собираются только в CI официальным Xcode: перепакованные SDK — серая зона лицензии Xcode.

## Структура

```
app/main.mm                    приложение (Objective-C++)
app/Info.plist                 шаблон Info.plist
app/entitlements/trollstore.plist  права для TrollStore-сборки
scripts/convert_shaders.py     GLSL OpenXRay → SPIR-V → MSL, отчёт report.json
scripts/build_ipa.sh           сборка и подпись двух вариантов IPA
.github/workflows/build.yml    CI на macos-15
```
