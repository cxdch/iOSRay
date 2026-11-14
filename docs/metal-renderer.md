# Metal-рендер для iOSRay (ветка `metal`)

Цель: заменить OpenGL ES (который iOS сама выполняет поверх Metal) собственным
бэкендом `xrRender_Metal`. Выигрыш — не «язык», а то, что GLES на A10 не умеет:

* **Тайловая память (TBDR).** G-буфер (position/normal, albedo, accum) живёт в тайле
  и не пишется в ОЗУ: `MTLStorageModeMemoryless` + `loadAction/storeAction = DontCare`.
  Для отложенного освещения R3 это главная экономия полосы памяти и нагрева.
* **Шейдеры собраны заранее** (`xrshaders.metallib` в CI) — на телефоне нет
  компиляции GLSL, нет подвисаний при первом появлении эффекта.
* **Состояния заранее**: `MTLRenderPipelineState`/`MTLDepthStencilState` кешируются
  по ключу вместо проверки GL-состояния на каждом вызове.
* **ASTC** — родной формат текстур (вместо DXT→RGBA8 на CPU).

## Слои

| OpenXRay (GL)                         | Metal                                             |
|---------------------------------------|---------------------------------------------------|
| `glHW` — контекст, swapchain          | `mtlHW` — `MTLDevice`, `CAMetalLayer` (SDL_Metal_CreateView) |
| `glR_Backend_Runtime` — set_* состояния | кеш PSO + depth-stencil, `MTLRenderCommandEncoder` |
| uniform по `glGetUniformLocation`     | константы пакуются в буфер по reflection JSON (`*.json` рядом с `.metal`) |
| `glTexture` (gli → glTexStorage)      | `MTLTexture`; DXT → ASTC (позже — заранее в CI/на устройстве) |
| `glSH_RT` (FBO)                       | `MTLRenderPassDescriptor`, memoryless для промежуточных целей |
| программные конвейеры GL              | `MTLFunction` из metallib по имени (`<shader>_vs`, `<shader>_ps`) |

Общий код `xrRender` (135 мест `USE_OGL`) получает ветки `USE_METAL`.

## Этапы (каждый — сборка, проверяемая на iPhone 7 Plus)

1. ✅ Шейдеры: GLSL → SPIR-V → MSL, 279/279 компилируются на A10 (XRProbe).
2. ✅ Офлайн `xrshaders.metallib` (279 шейдеров, 1,5 МБ) + reflection JSON в CI.
3. `mtlHW`: окно, очистка экрана, present. Меню рисуется пустым.
4. Буферы, вершинные форматы, константы, текстуры → главное меню (2D/UI).
5. Рендер-таргеты и проходы R3 → уровень, сначала без теней.
6. Тени, тонемап, bloom; memoryless G-буфер.
7. ASTC; удаление GLES-пути из iOS-сборки по готовности.

До готовности этапа 5 рабочей остаётся GLES-сборка из `main`.
