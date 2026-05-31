#!/bin/bash
# beer_to_war_thunder.sh - Запускает War Thunder при звуке открытия алюминиевой банки
#
# Скрипт работает в двух режимах:
#   1) Прослушивание микрофона: захват звука через ffmpeg в реальном времени.
#   2) Анализ аудиофайла: проверка готовой записи на наличие звука банки.
#      Полезен, когда живой микрофон недоступен (WSL без WSLg на Win10 и т.п.)
#      или когда нужен повторяемый тестовый кейс для демонстрации.
#
# В обоих режимах используется одинаковая логика классификации:
# характерный звук открытия банки = резкий щелчок (peak) +
# протяжное шипение с преобладанием высоких частот (rms + hiss-ratio).
# При обнаружении запускается War Thunder через Steam (App ID 236390).
#
# Поддерживаемые ОС:
#   - Linux (ffmpeg + PulseAudio)
#   - macOS (ffmpeg + AVFoundation)
#   - Windows через WSL2/WSLg 
#     автоматически на Win11; на Win10 рекомендуется режим --file)
#
# Требования: ffmpeg, awk, и установленный Steam с War Thunder.

set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"
readonly WAR_THUNDER_STEAM_ID=236390   

readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_CYAN='\033[0;36m'
readonly C_BOLD='\033[1m'

CHUNK_DURATION=1.2           # длина окна анализа 
PEAK_THRESHOLD=-12.0         # пик громкости должен быть громче 
RMS_THRESHOLD=-28.0          # средняя громкость должна быть громче 
HISS_RATIO_THRESHOLD=6.0     # |rms_total - rms_highpass| < этого → шипение 
HIGHPASS_FREQ=2000           # частота среза ФВЧ для анализа шипения 
COOLDOWN_SEC=30              # пауза после срабатывания 
ONCE=0                       # выйти после первого срабатывания
DRY_RUN=0                    # симуляция запуска 
CALIBRATE=0                  # режим калибровки
TEST_LAUNCH=0                # только проверить, что запуск игры работает
AUDIO_DEVICE=""              # пусто = устройство по умолчанию
INPUT_FILE=""                # если задан - анализируем файл вместо микрофона

OS_TYPE=""                   # linux | macos | wsl 
TMPDIR_BASE=""               # временная директория

log() {
    local color="$1"; shift
    local prefix="$1"; shift
    echo -e "${color}${prefix}${C_RESET} $*" >&2
    return 0
}
log_info()  { log "${C_BLUE}"   "[INFO]"  "$@"; }
log_ok()    { log "${C_GREEN}"  "[ OK ]"  "$@"; }
log_warn()  { log "${C_YELLOW}" "[WARN]"  "$@"; }
log_error() { log "${C_RED}"    "[ERR ]"  "$@"; }
log_step()  { log "${C_CYAN}"   "[STEP]"  "$@"; }

error_exit() { log_error "$1"; exit "${2:-1}"; }

#Справка 

print_help() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}
Запускает War Thunder, услышав открытие банки пива.

ИСПОЛЬЗОВАНИЕ:
    ${SCRIPT_NAME} [параметры]

ПАРАМЕТРЫ:
    -f, --file <PATH>        Проанализировать аудиофайл вместо записи с микрофона.
                             Поддерживаются wav, mp3, ogg, flac и др. форматы ffmpeg.
    -d, --device <NAME>      Аудиоустройство (по умолчанию: системное)
    -t, --chunk <SEC>        Длина окна анализа (по умолчанию: ${CHUNK_DURATION})
    -p, --peak <DB>          Порог пика, dB (по умолчанию: ${PEAK_THRESHOLD})
    -r, --rms <DB>           Порог RMS, dB (по умолчанию: ${RMS_THRESHOLD})
    -H, --hiss <DB>          Порог hiss_ratio, dB (по умолчанию: ${HISS_RATIO_THRESHOLD})
        --cooldown <SEC>     Пауза после срабатывания (по умолчанию: ${COOLDOWN_SEC})
        --once               Выйти после первого срабатывания
        --calibrate          Записать 3 сек и подобрать пороги
        --test-launch        Только проверить, что игра запускается
    -n, --dry-run            Не запускать игру, только сообщить о детекции
    -h, --help               Эта справка
    -v, --version            Версия

ПРИМЕРЫ:
    # Анализ готового аудиофайла:
    ${SCRIPT_NAME} --file ~/can_opening.wav --dry-run
    ${SCRIPT_NAME} -f ~/can_opening.wav --once

    # Откалибровать под свой микрофон
    ${SCRIPT_NAME} --calibrate

    # Режим с микрофоном
    ${SCRIPT_NAME}

    # Запустится один раз и выйдет
    ${SCRIPT_NAME} --once

    # Тренировка без запуска игры 
    ${SCRIPT_NAME} --dry-run

    # Проверить, что War Thunder вообще стартует через Steam
    ${SCRIPT_NAME} --test-launch
EOF
}

# Определение окружения

detect_os() {
    if [[ "$(uname)" == "Darwin" ]]; then
        OS_TYPE="macos"
    elif grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null; then
        OS_TYPE="wsl"
    else
        OS_TYPE="linux"
    fi
    log_info "Окружение: ${OS_TYPE}"
}

check_dependencies() {
    local deps=("ffmpeg" "awk" "grep" "date")
    local missing=()
    for cmd in "${deps[@]}"; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error_exit "Не найдены утилиты: ${missing[*]}. Установи их и повтори."
    fi
}

# Захват звука с микрофона

record_chunk() {
    local outfile="$1"
    local duration="$2"

    case "${OS_TYPE}" in
        macos)
            ffmpeg -y -hide_banner -loglevel error \
                -f avfoundation -i ":${AUDIO_DEVICE:-0}" \
                -t "${duration}" -ar 44100 -ac 1 \
                "${outfile}" </dev/null
            ;;
        linux|wsl)
            ffmpeg -y -hide_banner -loglevel error \
                -f pulse -i "${AUDIO_DEVICE:-default}" \
                -t "${duration}" -ar 44100 -ac 1 \
                "${outfile}" </dev/null
            ;;
    esac
}

analyze_chunk() {
    local file="$1"
    local out_full out_high

    out_full=$(ffmpeg -hide_banner -nostats -i "${file}" \
                      -af "volumedetect" -f null - 2>&1) \
        || { echo "-99 -99 -99"; return; }

    out_high=$(ffmpeg -hide_banner -nostats -i "${file}" \
                      -af "highpass=f=${HIGHPASS_FREQ},volumedetect" \
                      -f null - 2>&1) \
        || { echo "-99 -99 -99"; return; }

    local peak rms rms_high
    peak=$(echo "${out_full}" | awk '/max_volume:/  {print $5; exit}')
    rms=$(echo "${out_full}"  | awk '/mean_volume:/ {print $5; exit}')
    rms_high=$(echo "${out_high}" | awk '/mean_volume:/ {print $5; exit}')

    : "${peak:=-99}"
    : "${rms:=-99}"
    : "${rms_high:=-99}"

    echo "${peak} ${rms} ${rms_high}"
}

is_beer_opening() {
    local peak="$1" rms="$2" hiss_ratio="$3"

    # Три условия одновременно:
    #   1) Достаточно громкий пик       (peak > PEAK_THRESHOLD)
    #   2) Энергия не только в пике     (rms  > RMS_THRESHOLD)
    #   3) Преобладают высокие частоты  (hiss_ratio < HISS_RATIO_THRESHOLD)
    awk -v peak="${peak}" -v pt="${PEAK_THRESHOLD}" \
        -v rms="${rms}"   -v rt="${RMS_THRESHOLD}" \
        -v hr="${hiss_ratio}" -v ht="${HISS_RATIO_THRESHOLD}" \
        'BEGIN { exit !(peak > pt && rms > rt && hr < ht) }'
}

# Запуск War Thunder через Steam-протокол

launch_war_thunder() {
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "[DRY-RUN] Был бы запущен War Thunder (Steam ID ${WAR_THUNDER_STEAM_ID})"
        return 0
    fi

    log_step "Запуск War Thunder..."
    local steam_uri="steam://run/${WAR_THUNDER_STEAM_ID}"
    local rc=1

    case "${OS_TYPE}" in
        wsl)

            cmd.exe /c "start ${steam_uri}" >/dev/null 2>&1 && rc=0
            ;;
        macos)
            open "${steam_uri}" && rc=0
            ;;
        linux)

            if command -v steam &>/dev/null; then
                ( steam "${steam_uri}" >/dev/null 2>&1 & ) && rc=0
            elif command -v xdg-open &>/dev/null; then
                ( xdg-open "${steam_uri}" >/dev/null 2>&1 & ) && rc=0
            fi
            ;;
    esac

    if [[ ${rc} -eq 0 ]]; then
        log_ok "Танки на подходе. Не забудь убрать пиво подальше от клавиатуры "
    else
        log_error "Не удалось запустить War Thunder. Установлен ли Steam и игра?"
    fi
    return ${rc}
}

# Режим калибровки: записывает 3 сек, выдаёт измерения и рекомендации

run_calibration() {
    log_info "КАЛИБРОВКА"
    log_info "Сейчас будет 3 секунды записи. На счёт 'Старт!' открой банку."
    sleep 1

    for i in 3 2 1; do
        echo -e "  ${C_YELLOW}${i}...${C_RESET}"
        sleep 1
    done
    echo -e "  ${C_GREEN}${C_BOLD}СТАРТ! Открывай!${C_RESET}"

    local file="${TMPDIR_BASE}/calibrate.wav"
    record_chunk "${file}" 3.0 || error_exit "Запись не удалась. Проверь микрофон."

    local features peak rms rms_high hiss_ratio
    features=$(analyze_chunk "${file}")
    read -r peak rms rms_high <<< "${features}"
    hiss_ratio=$(awk "BEGIN {h=(${rms})-(${rms_high}); print (h<0)?-h:h}")

    echo
    log_info "Измерения:"
    printf "  Peak громкость:        %s dB\n"  "${peak}"
    printf "  RMS громкость:         %s dB\n"  "${rms}"
    printf "  RMS высоких (>%dГц):  %s dB\n" "${HIGHPASS_FREQ}" "${rms_high}"
    printf "  Hiss ratio:            %s dB (меньше = сильнее шипение)\n" "${hiss_ratio}"
    echo

    local peak_rec rms_rec hiss_rec
    peak_rec=$(awk "BEGIN {printf \"%.1f\", (${peak}) - 3}")
    rms_rec=$(awk  "BEGIN {printf \"%.1f\", (${rms})  - 3}")
    hiss_rec=$(awk "BEGIN {printf \"%.1f\", (${hiss_ratio}) + 2}")

    log_info "Рекомендуемые флаги для боевого режима:"
    echo -e "  ${C_BOLD}${SCRIPT_NAME} --peak ${peak_rec} --rms ${rms_rec} --hiss ${hiss_rec}${C_RESET}" >&2
}

analyze_audio_file() {
    local input="$1"

    if [[ ! -e "${input}" ]]; then
        error_exit "Аудиофайл не найден: '${input}'" 3
    fi
    if [[ ! -f "${input}" ]]; then
        error_exit "Указанный путь не является файлом: '${input}'" 3
    fi
    if [[ ! -r "${input}" ]]; then
        error_exit "Нет прав на чтение файла: '${input}'" 3
    fi

    log_info " Режим анализа файла: ${input}"

    local duration
    if command -v ffprobe &>/dev/null; then
        duration=$(ffprobe -v error -show_entries format=duration \
                           -of default=noprint_wrappers=1:nokey=1 "${input}" 2>/dev/null)
    else
        duration=$(ffmpeg -i "${input}" 2>&1 \
                   | awk -F'[:,]' '/Duration:/ {print $2*3600+$3*60+$4; exit}')
    fi

    if [[ -z "${duration}" ]]; then
        error_exit "Не удалось определить длительность файла. Возможно, неподдерживаемый формат." 4
    fi

    log_info "Длительность файла: ${duration} сек"
    log_info "Пороги: peak>${PEAK_THRESHOLD}dB, rms>${RMS_THRESHOLD}dB, hiss<${HISS_RATIO_THRESHOLD}dB"
    echo

    local total_chunks
    total_chunks=$(awk "BEGIN {printf \"%d\", ${duration} / ${CHUNK_DURATION}}")
    if (( total_chunks < 1 )); then
        total_chunks=1
    fi
    log_info "Файл будет разрезан на ${total_chunks} чанков по ${CHUNK_DURATION} сек"

    local triggered=0
    local chunk_count=0
    local start_sec=0

    while (( chunk_count < total_chunks )); do
        chunk_count=$((chunk_count + 1))
        local chunk_file="${TMPDIR_BASE}/chunk_${chunk_count}.wav"

        if ! ffmpeg -y -hide_banner -loglevel error \
                    -ss "${start_sec}" -i "${input}" \
                    -t "${CHUNK_DURATION}" -ar 44100 -ac 1 \
                    "${chunk_file}" </dev/null; then
            log_warn "Не удалось извлечь чанк #${chunk_count}, пропускаю"
            start_sec=$(awk "BEGIN {print ${start_sec} + ${CHUNK_DURATION}}")
            continue
        fi

        local features peak rms rms_high hiss_ratio
        features=$(analyze_chunk "${chunk_file}")
        read -r peak rms rms_high <<< "${features}"
        hiss_ratio=$(awk "BEGIN {h=(${rms})-(${rms_high}); print (h<0)?-h:h}")

        local marker="  "
        if is_beer_opening "${peak}" "${rms}" "${hiss_ratio}"; then
            marker=""
        fi
        printf "${C_CYAN}[чанк %3d/%3d]${C_RESET} t=%.2fs  peak=%6s  rms=%6s  hiss=%5s  %s\n" \
               "${chunk_count}" "${total_chunks}" "${start_sec}" \
               "${peak}" "${rms}" "${hiss_ratio}" "${marker}" >&2

        if is_beer_opening "${peak}" "${rms}" "${hiss_ratio}"; then
            log_ok "ОБНАРУЖЕНО ОТКРЫТИЕ БАНКИ на ${start_sec}с! (peak=${peak} rms=${rms} hiss=${hiss_ratio})"
            launch_war_thunder || log_warn "Запуск не удался"
            triggered=1

            if [[ "${ONCE}" -eq 1 ]]; then
                log_info "Режим --once: анализ остановлен."
                return 0
            fi
        fi

        start_sec=$(awk "BEGIN {print ${start_sec} + ${CHUNK_DURATION}}")
    done

    echo
    if (( triggered == 0 )); then
        log_warn "Звук открытия банки в файле не обнаружен."
        log_info "Возможно, нужно смягчить пороги через --peak / --rms / --hiss"
        return 1
    fi
    return 0
}

# Основной цикл прослушки микрофона

run_listening_loop() {
    echo
    log_info "Слушаю микрофон. Открой банку - запустятся танки."
    log_info "Пороги: peak>${PEAK_THRESHOLD}dB, rms>${RMS_THRESHOLD}dB, hiss<${HISS_RATIO_THRESHOLD}dB"
    log_info "Кулдаун после срабатывания: ${COOLDOWN_SEC}с"
    log_info "Прервать: Ctrl+C"
    echo

    local last_trigger=0
    local chunk_count=0

    while true; do
        local chunk_file="${TMPDIR_BASE}/chunk.wav"

        if ! record_chunk "${chunk_file}" "${CHUNK_DURATION}"; then
            log_warn "Запись чанка не удалась, пауза 1 сек..."
            sleep 1
            continue
        fi
        chunk_count=$((chunk_count + 1))

        local features peak rms rms_high hiss_ratio
        features=$(analyze_chunk "${chunk_file}")
        read -r peak rms rms_high <<< "${features}"
        hiss_ratio=$(awk "BEGIN {h=(${rms})-(${rms_high}); print (h<0)?-h:h}")

        printf "\r${C_CYAN}[чанк %4d]${C_RESET} peak=%6s  rms=%6s  hiss=%5s  " \
               "${chunk_count}" "${peak}" "${rms}" "${hiss_ratio}"

        local now
        now=$(date +%s)
        if (( now - last_trigger < COOLDOWN_SEC )); then
            continue
        fi

        if is_beer_opening "${peak}" "${rms}" "${hiss_ratio}"; then
            echo 
            log_ok "ОБНАРУЖЕНО ОТКРЫТИЕ БАНКИ! (peak=${peak} rms=${rms} hiss=${hiss_ratio})"
            launch_war_thunder || log_warn "Запуск не удался, продолжаю слушать"
            last_trigger=${now}

            if [[ "${ONCE}" -eq 1 ]]; then
                log_info "Режим --once: завершаю работу."
                break
            fi
        fi
    done
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--file)
                if [[ -z "${2:-}" ]]; then
                    error_exit "Параметр '$1' требует значения" 2
                fi
                INPUT_FILE="$2"; shift 2 ;;
            -d|--device)
                if [[ -z "${2:-}" ]]; then
                    error_exit "Параметр '$1' требует значения" 2
                fi
                AUDIO_DEVICE="$2"; shift 2 ;;
            -t|--chunk)
                if ! [[ "${2:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    error_exit "Параметр '$1': ожидается число, получено '${2:-}'" 2
                fi
                CHUNK_DURATION="$2"; shift 2 ;;
            -p|--peak)
                if ! [[ "${2:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                    error_exit "Параметр '$1': ожидается число" 2
                fi
                PEAK_THRESHOLD="$2"; shift 2 ;;
            -r|--rms)
                if ! [[ "${2:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                    error_exit "Параметр '$1': ожидается число" 2
                fi
                RMS_THRESHOLD="$2"; shift 2 ;;
            -H|--hiss)
                if ! [[ "${2:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                    error_exit "Параметр '$1': ожидается число" 2
                fi
                HISS_RATIO_THRESHOLD="$2"; shift 2 ;;
            --cooldown)
                if ! [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                    error_exit "Параметр '$1': ожидается целое число" 2
                fi
                COOLDOWN_SEC="$2"; shift 2 ;;
            --once)         ONCE=1; shift ;;
            --calibrate)    CALIBRATE=1; shift ;;
            --test-launch)  TEST_LAUNCH=1; shift ;;
            -n|--dry-run)   DRY_RUN=1; shift ;;
            -h|--help)      print_help; exit 0 ;;
            -v|--version)   echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"; exit 0 ;;
            *) error_exit "Неизвестный параметр: '$1'. См. --help" 2 ;;
        esac
    done
}

# Очистка временных файлов

cleanup() {
    [[ -n "${TMPDIR_BASE}" && -d "${TMPDIR_BASE}" ]] && rm -rf "${TMPDIR_BASE}"
}

main() {
    parse_args "$@"

    {
        echo -e "${C_BOLD}${C_CYAN}"
        echo "═══════════════════════════════════════════════════════════════"
        echo "  ${SCRIPT_NAME} v${SCRIPT_VERSION}  - War Thunder"
        echo "═══════════════════════════════════════════════════════════════"
        echo -e "${C_RESET}"
    } >&2

    detect_os
    check_dependencies

    if ! TMPDIR_BASE=$(mktemp -d -t beer2wt.XXXXXX); then
        error_exit "Не удалось создать временную директорию"
    fi
    trap cleanup EXIT
    trap 'echo; log_info "Остановлено пользователем"; exit 0' INT TERM

    if [[ "${TEST_LAUNCH}" -eq 1 ]]; then
        log_info "Тест запуска War Thunder..."
        launch_war_thunder
        exit $?
    fi

    if [[ "${CALIBRATE}" -eq 1 ]]; then
        run_calibration
        exit 0
    fi

    if [[ -n "${INPUT_FILE}" ]]; then
        analyze_audio_file "${INPUT_FILE}"
        exit $?
    fi

    run_listening_loop
}

main "$@"