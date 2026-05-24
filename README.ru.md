# vibe-coding-auto-resume

Автоматическое возобновление сессий Claude Code CLI после rate limit: длинные agentic-задачи, vibe coding и ночные джобы переживают 5-часовой и недельный лимиты без ручного перезапуска.

[English](README.md) | [中文](README.zh.md) | [Français](README.fr.md) | [***Русский***](README.ru.md)

## Проблема

Если вы используете Claude Code (`claude`) для реальной работы — длинные agentic-задачи, многочасовые рефакторинги, vibe-coding по SSH — рано или поздно упираетесь в стену:

- 5-часовое окно rate limit обрывает задачу посередине. Нужно запомнить время reset и вручную запустить `claude --continue`.
- Недельные лимиты делают то же самое, только на более длинной шкале.
- Обрыв SSH убивает процесс целиком. Вернулись с обеда — сессии нет.
- Нет встроенного способа увидеть, сколько текущего block уже сожжено.
- Существующие wrappers, ловившие сообщение о лимите по тексту TUI, ломались сразу же, как только Claude переформулировал строку.

`vibe-coding-auto-resume` — это небольшой набор bash-скриптов, который решает всё это без тяжёлых зависимостей.

## Что он делает

- **Запускает `claude` внутри tmux**, так что обрыв SSH, закрытие терминала или сон ноутбука не убивают сессию.
- **Трёхслойное детектирование rate limit**: парсинг JSONL из `~/.claude/projects/*.jsonl` (L1), regex по pane tmux против verbatim-текста TUI (L2), опциональная LLM-классификация (L3) для изменений формулировок и edge case'ов.
- **Авто-возобновление после reset**: спит до извлечённого времени reset + небольшой pad, затем перезапускает через `claude --resume <session-uuid>` (предпочтительно, сохраняет cache) или `claude --continue` (fallback).
- **Автоматический захват session UUID** через наблюдение за каталогом JSONL, чтобы resume точно попал в нужную сессию и обошёл баг инвалидации cache в `--continue`.
- **Файл преемственности `HANDOFF.md`** для контекста, который должен пережить даже полный перезапуск.
- **L1+L2 работают без внешних зависимостей** (нужны только `bash`, `jq`, `tmux`, `curl`). L3 — opt-in, по умолчанию выключен.

Фоновый soft-cap monitor (v2), предупреждающий Claude о приближении к лимиту, чтобы тот успел сохранить прогресс, — **запланирован, ещё не реализован**.

## Установка

```bash
git clone https://github.com/zhihuiyuze/vibe-coding-auto-resume.git ~/dev/claude-auto-continue
cd ~/dev/claude-auto-continue
./install.sh
sudo apt install tmux  # если не установлен
source ~/.bashrc
```

Установщик идемпотентный: создаёт symlinks `vibe-run` и `vibe-session-capture` в `~/.local/bin/`, дописывает небольшой snippet в `~/.tmux.conf` и функцию `vibe work` в `~/.bashrc`. Ничего не трогает в `~/.claude/`.

## Использование

Типичный workflow:

```bash
vibe work            # вход в tmux-сессию "claude" в cwd вашего проекта
vibe-run      # используйте вместо `claude` — те же флаги, то же поведение
# Ctrl+b d чтобы отсоединиться. SSH может оборваться; сессия продолжает работать.
# Позже: vibe work снова, чтобы переподключиться.
```

Когда `claude` завершается из-за rate limit, `vibe-run` парсит время reset, спит до него (+60s pad) и возобновляет ту же session UUID. Когда `claude` выходит штатно или с реальной ошибкой, wrapper выходит с тем же кодом — он **не** ретраит вслепую.

## Опциональное включение L3 LLM

L1 (парсинг JSONL) и L2 (regex по pane) покрывают типичные сценарии без единого внешнего вызова. Для лучшей устойчивости к изменениям формулировок TUI и обработки edge case'ов — а также для извлечения времени reset, которое regex L2 пропускает — можно включить L3 LLM-классификацию.

Поддерживаемые провайдеры:

- **DeepSeek** (`DEEPSEEK_API_KEY`, модель `deepseek-chat`) — самый дешёвый
- **Anthropic Claude** (`ANTHROPIC_API_KEY`, модель `claude-haiku-4-5`)
- **OpenAI** (`OPENAI_API_KEY`, модель `gpt-4o-mini`)
- **Ollama** (локально, `OLLAMA_HOST`) — интерфейс реализован, на данный момент `[untested]`, ждёт валидации на GPU

Чтобы включить:

```bash
export DEEPSEEK_API_KEY=sk-...   # добавьте в ~/.bashrc для постоянства
./install.sh                     # перезапустить; обнаружит ключ и предложит opt-in
source ~/.bashrc
```

**О приватности**: при включённом L3 последние ~30 строк вашего tmux-pane (хвост диалога, превью файлов) отправляются выбранному провайдеру для классификации. Базовая редактура секретов (`sk-*`, `Bearer *`, `*_SECRET=*`, длинный base64) включена по умолчанию, но **не** даёт гарантий. Не включайте L3 на pane, содержащем данные, которые вы не вставили бы в чат-интерфейс этого провайдера. Отказ от opt-in оставляет режим L1+L2 даже при наличии ключа.

## Как работает детектирование (TL;DR)

Три слоя работают по порядку. **L1** непрерывно знает, сколько от текущего 5-часового block использовано, суммируя `message.usage.{input,output,cache_read}_tokens` по JSONL-файлам текущего проекта; это управляет pre-flight отказом на soft cap. **L2** запускает `tmux capture-pane` при выходе и grep'ает хвост на verbatim-строки rate limit (`5-hour limit reached ∙ resets ...`, `weekly limit reached`, `Approaching 5-hour limit`) и извлекает время reset. **L3** (если включён) отправляет тот же хвост в LLM и получает структурированный JSON `{status, reset_time, idle, modal_open}` для случаев, которые L2 не умеет парсить.

Полное обоснование в [`docs/architecture.md`](docs/architecture.md) и [`docs/design/001-three-layer-detection.md`](docs/design/001-three-layer-detection.md).

## Переменные окружения

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `CC_LLM_PROVIDER` | авто-детект, или `none` | Выбор провайдера L3 (`deepseek` / `claude` / `openai` / `ollama` / `none`). `none` принудительно оставляет L1+L2 даже при наличии ключей. |
| `CC_USAGE_THRESHOLD` | `0.75` | Доля soft cap. Pre-flight отказывается запускать новый запрос выше этого. |
| `CC_RESUME_MODE` | `auto` | `auto` = `--resume <sid>` с fallback на `--continue`. `session-id` = строгий UUID. `continue` = всегда `--continue`. |
| `CC_RESUME_MAX_CYCLES` | `1` | Сколько циклов авто-возобновления на один вызов wrapper (`0` = без ограничений). |
| `CC_COMPACTION_CHOICE` | `keep` | На редком compaction-prompt (контекст слишком большой) после resume: `keep` (полный контекст) или `compact` (Claude резюмирует сам). |

Менее частые переключатели (`CC_SLEEP_PAD`, `CC_LLM_REDACT`, `CC_PANE_TAIL_LINES`, `CC_PEAK_FALLBACK`, `CC_SESSION_FILE`, `CC_LLM_MODEL`) задокументированы в шапке `bin/vibe-run`.

## Вклад в проект

Сначала прочитайте [`AGENTS.md`](AGENTS.md) — это единая точка входа для контрибьюторов. Проект использует **spec-first workflow**: каждая фича начинается с design-документа `docs/design/00X-<name>.md` (шаблон в [`docs/design/README.md`](docs/design/README.md)), который ревьюится до написания кода. Bug fixes и мелкие правки можно отправлять сразу PR'ом.

Особенно приветствуются новые TUI-паттерны: если Claude Code когда-нибудь выдаст сообщение о rate limit или modal, которое мы пока не матчим, вставьте verbatim-текст в `tests/fixtures/<name>.txt` и откройте PR.

## Лицензия

MIT.
