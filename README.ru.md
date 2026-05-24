# vibe-coding-auto-resume

Оборачиваем CLI Claude Code в tmux, чтобы длинные agentic-задачи переживали rate-limit, обрывы SSH и ночные прогоны — без нянченья часов сброса.

[English](README.md) | [中文](README.zh.md) | [Français](README.fr.md) | [***Русский***](README.ru.md)

## Установка (один раз)

```bash
git clone https://github.com/zhihuiyuze/vibe-coding-auto-resume.git ~/dev/claude-auto-continue
cd ~/dev/claude-auto-continue
./install.sh
sudo apt install tmux  # только если отсутствует — установщик скажет
source ~/.bashrc
```

Установщик идемпотентен. Создаёт symlinks `vibe-run`, `vibe-status`, `vibe-session-capture` в `~/.local/bin/`, добавляет shell-функцию `vibe` в `~/.bashrc` и snippet tmux. Никогда не трогает `~/.claude/` и не запускает `sudo` за вас.

---

## Три сценария — выберите свой

### 1. Я начинаю новую задачу в Claude

```bash
cd ~/dev/<ваш-проект>
vibe work                  # cd сюда + открыть именованную tmux-сессию
vibe run                   # замена `claude` — те же флаги, тот же UI
```

Дальше работаете с Claude как обычно. Когда 5-часовой блок исчерпан, `vibe run` это замечает, спит до сброса и перезапускает **ту же session UUID** автоматически. Если появится новое интерактивное модальное окно Anthropic (`What do you want to do? 1. Stop and wait …`), wrapper сам выберет безопасный вариант «Stop and wait».

Оставить сессию работать и уйти: `Ctrl+b d`. Вернуться: `vibe work`.

### 2. Хочу продолжить сессию, начатую раньше

Если помните session UUID (из `~/.claude/projects/` или скопированный из лога предыдущего запуска):

```bash
cd ~/dev/<ваш-проект>
vibe work
vibe run --resume <session-uuid>
```

Если не помните, но это последняя сессия в этом проекте:

```bash
vibe work
vibe run --mode continue                    # эквивалент `claude --continue` + автовозобновление при лимите
```

Список кандидатов — по именам JSONL-файлов:

```bash
ls -t ~/.claude/projects/$(pwd | sed 's|/|-|g')/*.jsonl | head -5
# имя файла без `.jsonl` — это session UUID
```

### 3. SSH оборвался — как убедиться, что задача жива, и вернуться к ней

tmux-сессия — настоящий владелец процесса; `claude` держит tmux, а не ваш shell. SSH умер, сессия живёт. Пошагово:

```bash
ssh you@server                              # 1. переподключаемся
tmux ls                                     # 2. жива ли ваша vibe-* сессия?
                                            #    ожидается, например: "vibe-default: 1 windows (...)"
vibe work                                   # 3. реаттач (или `vibe work <name>` если имя задавали)
                                            #    попадаете ровно туда, где остановились
```

После реаттача — посмотреть, что произошло без вас: `Ctrl+b [`, далее PageUp / стрелки, `q` для выхода из scrollback. Если за это время был rate limit, wrapper уже обработал — увидите записи `[vibe-run] Sleeping … until …` и возобновление.

**Подсмотреть, не аттачась** (например, с другой машины — просто статус):

```bash
ssh you@server "tmux ls"                                              # что живо
ssh you@server "tmux capture-pane -t vibe-default -p | tail -50"      # последние 50 строк pane
ssh you@server "vibe status"                                          # текущая утилизация блока
```

**Если `tmux ls` отвечает `no server running`** — машина перезагрузилась или tmux был OOM-killed. tmux-сессия потеряна, но JSONL-история Claude — нет. Используйте сценарий 2 выше (`vibe run --resume <uuid>` или `vibe run --mode continue`) чтобы продолжить.

---

## Опционально: умнее детекция через LLM

L1 (парсинг JSONL) и L2 (regex по pane) покрывают типовые формы rate limit без единого внешнего вызова. Чтобы устойчивее обрабатывать смену формулировок TUI и извлекать время сброса, которое regex упускает, включите L3:

```bash
echo 'DEEPSEEK_API_KEY=sk-...' >> ~/.config/vibe/env   # chmod 600, создан установщиком
chmod 600 ~/.config/vibe/env
source ~/.bashrc
```

Поддерживаемые провайдеры: **DeepSeek** (самый дешёвый, ~$0.05/блок), **Anthropic Claude Haiku**, **OpenAI gpt-4o-mini**, **Ollama** (локально, `[untested]` — нужна валидация на GPU).

**Приватность**: при включённом L3 последние ~30 строк pane (хвост диалога + видимые превью файлов) отправляются выбранному провайдеру одним вызовом классификации за один limit-event. Базовая редактура секретов (`sk-*`, `Bearer *`, `*_SECRET=*`, длинный base64) включена по умолчанию, но не даёт гарантий. Откажитесь от opt-in (или `vibe run --no-l3`) — останетесь полностью локально.

---

## Что под капотом

Когда `claude` завершается, `vibe run` запускает три проверки по порядку:

- **L1** суммирует `message.usage.{input,output,cache_read}_tokens` по JSONL текущего проекта, чтобы знать, сколько от 5-часового блока сожжено и когда сброс.
- **L2** запускает `tmux capture-pane` и grep'ает хвост на verbatim-строки TUI (`5-hour limit reached ∙ resets …`, `weekly limit reached`, `Approaching 5-hour limit`, плюс новая модалка «Stop and wait for limit to reset»). Извлекает время сброса.
- **L3** (опционально) отправляет тот же хвост в LLM и получает `{status, reset_time, idle, modal_open}` для случаев, которые L2 не парсит.

Когда `claude` выходит штатно или с реальной ошибкой (crash, MCP failure, /exit), wrapper выходит с тем же кодом — **не** ретраит вслепую. Автовозобновление срабатывает только при положительно детектированном rate-limit-сигнале. Подробности в [`docs/architecture.md`](docs/architecture.md) и [`docs/design/001-three-layer-detection.md`](docs/design/001-three-layer-detection.md).

## CLI-флаги

```
vibe run [...args]
  --resume <uuid>          возобновить конкретную сессию (для всех циклов)
  --threshold <0..1>       мягкий потолок (по умолчанию выключен — «сжигаем блок»)
  --max-cycles <n>         циклов возобновления за вызов (0 = без лимита, по умолчанию 1)
  --mode auto|session-id|continue
  --provider deepseek|claude|openai|ollama
  --no-l3                  принудительно только L1+L2
  --dangerously-skip-permissions
  -p "prompt"
  ... любые другие флаги уходят прямо в claude
```

## Переменные окружения (основные)

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `CC_LLM_PROVIDER` | авто-детект | `deepseek` / `claude` / `openai` / `ollama` / `none` |
| `CC_USAGE_THRESHOLD` | _не задана_ (off) | мягкий потолок opt-in (например `0.80`) для резерва бюджета |
| `CC_RESUME_MODE` | `auto` | `auto` / `session-id` (строгий UUID) / `continue` |
| `CC_RESUME_MAX_CYCLES` | `1` | `0` = без ограничений по циклам на один вызов |
| `CC_SLEEP_PAD` | `60` | секунд добавляется к времени сброса перед перезапуском |

Остальные переключатели (`CC_LLM_REDACT`, `CC_PANE_TAIL_LINES`, `CC_MODAL_POLL_INTERVAL`, …) задокументированы в шапке `bin/vibe-run`.

## Мульти-сессии

`vibe work <name>` создаёт изолированную tmux-сессию + state-каталог. Полезно для параллельного запуска нескольких задач Claude:

```bash
vibe work feature-a    # tmux-сессия "vibe-feature-a"
# Ctrl+b d, потом в другом шелле:
vibe work bugfix       # tmux-сессия "vibe-bugfix", отдельный кэш UUID
```

`vibe work` без имени использует детерминированно-случайное имя из хэша cwd — вернувшись в тот же проект, всегда попадаете в ту же сессию.

## Вклад в проект

Сначала прочитайте [`AGENTS.md`](AGENTS.md) — единая точка входа. Проект использует **spec-first workflow**: каждая фича начинается с design-документа `docs/design/00X-<name>.md` ([шаблон](docs/design/README.md)) — ревью до кода.

Если Claude Code однажды покажет сообщение о лимите или модалку, которую мы не матчим, вставьте verbatim в `tests/fixtures/<name>.txt` и откройте PR.

## Лицензия

MIT.
