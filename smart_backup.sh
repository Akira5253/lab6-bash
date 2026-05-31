#!/bin/bash
# smart_backup.sh - Умный скрипт резервного копирования директорий
#
# Создаёт сжатые tar.gz архивы с временными метками, проверяет их целостность
# и автоматически удаляет старые копии.
#
# Использование:
#   ./smart_backup.sh -s <источник> -d <назначение> [параметры]
#
# Запуск с --help для подробной справки.

set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"

readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_CYAN='\033[0;36m'
readonly C_BOLD='\033[1m'

SOURCE_DIR=""
DEST_DIR=""
KEEP_COUNT=5              # Сколько последних архивов хранить
COMPRESSION_LEVEL=6       # Уровень сжатия gzip (1-9)
EXCLUDE_PATTERNS=()       # Массив шаблонов для исключения
LOG_FILE=""               # Опциональный файл журнала
DRY_RUN=0                 # 1 = режим симуляции, без реальных изменений
VERIFY=1                  # 1 = проверять архив после создания
QUIET=0                   # 1 = только ошибки

# Логирование

log() {
    local level="$1"; shift
    local color="$1"; shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${timestamp}] [${level}] ${message}"

    if [[ "${QUIET}" -eq 0 || "${level}" == "ERROR" ]]; then
        echo -e "${color}${line}${C_RESET}" >&2
    fi

    [[ -n "${LOG_FILE}" ]] && echo "${line}" >> "${LOG_FILE}"

    return 0
}

log_info()  { log "INFO"  "${C_BLUE}"   "$@"; }
log_ok()    { log "OK"    "${C_GREEN}"  "$@"; }
log_warn()  { log "WARN"  "${C_YELLOW}" "$@"; }
log_error() { log "ERROR" "${C_RED}"    "$@"; }
log_step()  { log "STEP"  "${C_CYAN}"   "$@"; }

# Сообщение об ошибке + выход с указанным кодом (по умолчанию 1)
error_exit() {
    local code="${2:-1}"
    log_error "$1"
    exit "${code}"
}

# Справка

print_help() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} - Умное резервное копирование

ИСПОЛЬЗОВАНИЕ:
    ${SCRIPT_NAME} -s <SOURCE> -d <DEST> [параметры]

ОБЯЗАТЕЛЬНЫЕ ПАРАМЕТРЫ:
    -s, --source <DIR>      Директория для резервной копии
    -d, --dest <DIR>        Куда складывать архивы

ДОПОЛНИТЕЛЬНЫЕ ПАРАМЕТРЫ:
    -k, --keep <N>          Сколько архивов хранить (по умолчанию: 5)
    -c, --compression <1-9> Уровень сжатия gzip (по умолчанию: 6)
    -e, --exclude <PATTERN> Исключить файлы/папки по шаблону (можно повторять)
    -l, --log <FILE>        Дублировать журнал в файл
    -n, --dry-run           Симуляция без реальных изменений
        --no-verify         Не проверять целостность созданного архива
    -q, --quiet             Тихий режим (только ошибки)
    -h, --help              Показать эту справку
    -v, --version           Показать версию

ПРИМЕРЫ:
    ${SCRIPT_NAME} -s ~/documents -d /tmp/backup
    ${SCRIPT_NAME} -s ~/project -d /tmp/backup -k 10 \\
        -e 'node_modules' -e '*.log' -e '.git'
    ${SCRIPT_NAME} -s ~/important -d /tmp/backup -n -l /tmp/backup.log

КОДЫ ВОЗВРАТА:
    0 - успех            3 - нет исходной директории
    1 - общая ошибка     4 - ошибка создания архива
    2 - неверные флаги   5 - архив не прошёл проверку
EOF
}


# Вспомогательные функции

# Получить размер файла или директории в байтах
get_size_bytes() {
    du -sb "$1" 2>/dev/null | awk '{print $1}'
}

format_size() {
    local bytes="$1"
    if   (( bytes >= 1073741824 )); then awk "BEGIN {printf \"%.2fG\", ${bytes}/1073741824}"
    elif (( bytes >= 1048576 ));    then awk "BEGIN {printf \"%.2fM\", ${bytes}/1048576}"
    elif (( bytes >= 1024 ));       then awk "BEGIN {printf \"%.2fK\", ${bytes}/1024}"
    else                                  echo "${bytes}B"
    fi
}

# Проверка наличия всех нужных утилит
check_dependencies() {
    local deps=("tar" "gzip" "du" "awk" "find" "sort" "date" "basename" "dirname")
    local missing=()

    for cmd in "${deps[@]}"; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error_exit "Отсутствуют необходимые утилиты: ${missing[*]}"
    fi
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        print_help
        exit 2
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--source)
                if [[ -z "${2:-}" ]]; then
                    error_exit "Параметр '$1' требует значения" 2
                fi
                SOURCE_DIR="$2"; shift 2 ;;
            -d|--dest)
                if [[ -z "${2:-}" ]]; then
                    error_exit "Параметр '$1' требует значения" 2
                fi
                DEST_DIR="$2"; shift 2 ;;
            -k|--keep)
                if [[ -z "${2:-}" ]]; then
                    error_exit "Параметр '$1' требует значения" 2
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -lt 1 ]]; then
                    error_exit "Значение -k должно быть целым числом >= 1, получено: '$2'" 2
                fi
                KEEP_COUNT="$2"; shift 2 ;;
            -c|--compression)
                if [[ -z "${2:-}" ]]; then
                    error_exit "Параметр '$1' требует значения" 2
                fi
                if ! [[ "$2" =~ ^[1-9]$ ]]; then
                    error_exit "Уровень сжатия должен быть от 1 до 9, получено: '$2'" 2
                fi
                COMPRESSION_LEVEL="$2"; shift 2 ;;
            -e|--exclude)
                if [[ -z "${2:-}" ]]; then
                    error_exit "Параметр '$1' требует значения" 2
                fi
                EXCLUDE_PATTERNS+=("$2"); shift 2 ;;
            -l|--log)
                if [[ -z "${2:-}" ]]; then
                    error_exit "Параметр '$1' требует значения" 2
                fi
                LOG_FILE="$2"; shift 2 ;;
            -n|--dry-run)  DRY_RUN=1; shift ;;
            --no-verify)   VERIFY=0;  shift ;;
            -q|--quiet)    QUIET=1;   shift ;;
            -h|--help)     print_help; exit 0 ;;
            -v|--version)  echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"; exit 0 ;;
            *) error_exit "Неизвестный параметр: '$1'. Используйте --help" 2 ;;
        esac
    done

    if [[ -z "${SOURCE_DIR}" ]]; then
        error_exit "Не указан источник (-s/--source)" 2
    fi
    if [[ -z "${DEST_DIR}" ]]; then
        error_exit "Не указано назначение (-d/--dest)" 2
    fi
}

validate_environment() {
    log_step "Проверка окружения..."

    if [[ ! -e "${SOURCE_DIR}" ]]; then
        error_exit "Источник не существует: '${SOURCE_DIR}'" 3
    fi
    if [[ ! -d "${SOURCE_DIR}" ]]; then
        error_exit "Источник не является директорией: '${SOURCE_DIR}'" 3
    fi
    if [[ ! -r "${SOURCE_DIR}" ]]; then
        error_exit "Нет прав на чтение источника: '${SOURCE_DIR}'" 3
    fi

    if [[ ! -d "${DEST_DIR}" ]]; then
        log_warn "Директория назначения отсутствует: '${DEST_DIR}'"
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            log_info "[DRY-RUN] Была бы создана директория: '${DEST_DIR}'"
        else
            if ! mkdir -p "${DEST_DIR}"; then
                error_exit "Не удалось создать '${DEST_DIR}'"
            fi
            log_info "Создана директория: '${DEST_DIR}'"
        fi
    fi

    if [[ -d "${DEST_DIR}" && ! -w "${DEST_DIR}" ]]; then
        error_exit "Нет прав на запись в '${DEST_DIR}'"
    fi

    # Подготовка файла журнала
    if [[ -n "${LOG_FILE}" ]]; then
        local log_dir; log_dir="$(dirname "${LOG_FILE}")"
        if [[ ! -d "${log_dir}" ]]; then
            if ! mkdir -p "${log_dir}"; then
                error_exit "Не удалось создать директорию журнала: '${log_dir}'"
            fi
        fi
        if ! touch "${LOG_FILE}"; then
            error_exit "Не удалось открыть файл журнала: '${LOG_FILE}'"
        fi
    fi

    log_ok "Окружение в порядке"
}

create_backup() {
    local source_basename; source_basename="$(basename "${SOURCE_DIR}")"
    local parent_dir;      parent_dir="$(dirname "${SOURCE_DIR}")"
    local timestamp;       timestamp="$(date '+%Y%m%d_%H%M%S')"
    local archive_name="${source_basename}_${timestamp}.tar.gz"
    local archive_path="${DEST_DIR}/${archive_name}"

    log_step "Создание архива: ${archive_name}"

    local tar_args=("--create" "--file=${archive_path}")
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        tar_args+=("--exclude=${pattern}")
        log_info "  → Исключение: '${pattern}'"
    done

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "[DRY-RUN] Был бы выполнен: tar ${tar_args[*]} --gzip -C '${parent_dir}' '${source_basename}'"
        log_info "[DRY-RUN] Архив был бы сохранён: ${archive_path}"
        echo "${archive_path}"
        return 0
    fi

    local source_bytes; source_bytes="$(get_size_bytes "${SOURCE_DIR}")"
    log_info "  → Размер источника: $(format_size "${source_bytes}")"

    local t_start; t_start="$(date +%s)"

    if ! tar "${tar_args[@]}" -I "gzip -${COMPRESSION_LEVEL}" \
             -C "${parent_dir}" "${source_basename}"; then
        local rc=$?
        [[ -f "${archive_path}" ]] && rm -f "${archive_path}"
        error_exit "tar завершился с кодом ${rc}" 4
    fi

    local elapsed=$(( $(date +%s) - t_start ))
    local archive_bytes; archive_bytes="$(get_size_bytes "${archive_path}")"

    local ratio="N/A"
    if (( source_bytes > 0 )); then
        ratio="$(awk "BEGIN {printf \"%.1f%%\", (${archive_bytes}/${source_bytes})*100}")"
    fi

    log_ok "Архив создан за ${elapsed}с"
    log_info "  → Путь:   ${archive_path}"
    log_info "  → Размер: $(format_size "${archive_bytes}")"
    log_info "  → Сжатие: ${ratio} от исходного размера"

    echo "${archive_path}"
}

# Проверка целостности созданного архива

verify_backup() {
    local archive_path="$1"

    [[ "${VERIFY}"  -eq 0 ]] && { log_info "Проверка пропущена (--no-verify)"; return 0; }
    [[ "${DRY_RUN}" -eq 1 ]] && { log_info "[DRY-RUN] Проверка была бы выполнена"; return 0; }

    log_step "Проверка целостности архива..."

    if ! tar --test --file="${archive_path}" --gzip &>/dev/null; then
        log_error "Архив повреждён, удаляю: ${archive_path}"
        rm -f "${archive_path}" || log_warn "Не удалось удалить повреждённый файл"
        exit 5
    fi

    log_ok "Архив прошёл проверку целостности"
}

rotate_backups() {
    local source_basename; source_basename="$(basename "${SOURCE_DIR}")"
    local pattern="${source_basename}_*.tar.gz"

    log_step "Ротация старых архивов (хранить: ${KEEP_COUNT})..."

    local archives=()
    while IFS= read -r -d '' file; do
        archives+=("${file}")
    done < <(find "${DEST_DIR}" -maxdepth 1 -name "${pattern}" -type f -printf '%T@ %p\0' 2>/dev/null \
             | sort -zrn \
             | cut -z -d' ' -f2-)

    local total="${#archives[@]}"
    log_info "  → Найдено архивов: ${total}"

    if (( total <= KEEP_COUNT )); then
        log_info "  → Лимит не превышен, удалять нечего"
        return 0
    fi

    local removed=0
    for (( i = KEEP_COUNT; i < total; i++ )); do
        local old="${archives[$i]}"
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            log_info "[DRY-RUN] Был бы удалён: ${old}"
        else
            # rm - критичная команда: проверяем код возврата
            if rm -f "${old}"; then
                log_info "  → Удалён: $(basename "${old}")"
                ((removed++))
            else
                log_warn "Не удалось удалить: ${old}"
            fi
        fi
    done

    log_ok "Ротация завершена (удалено: ${removed})"
}

main() {
    parse_args "$@"
    check_dependencies


    if [[ "${QUIET}" -eq 0 ]]; then
        {
            echo -e "${C_BOLD}${C_CYAN}"
            echo "═══════════════════════════════════════════════════"
            echo "  ${SCRIPT_NAME} v${SCRIPT_VERSION}"
            echo "  Источник:   ${SOURCE_DIR}"
            echo "  Назначение: ${DEST_DIR}"
            echo "  Хранить:    ${KEEP_COUNT} архивов"
            [[ "${DRY_RUN}" -eq 1 ]] && echo "  Режим:      DRY-RUN"
            echo "═══════════════════════════════════════════════════"
            echo -e "${C_RESET}"
        } >&2
    fi

    local t_start; t_start="$(date +%s)"

    validate_environment
    local archive_path; archive_path="$(create_backup)"
    verify_backup "${archive_path}"
    rotate_backups

    local total=$(( $(date +%s) - t_start ))
    log_ok "Готово! Общее время: ${total}с"
}

main "$@"