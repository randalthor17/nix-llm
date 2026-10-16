#!/usr/bin/env bash 

# Function to parse arguments and set up common variables
parse_args() {
    USE_AMD=false
    USE_METAL=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --amd)
                USE_AMD=true
                shift
                ;;
            --metal)
                USE_METAL=true
                shift
                ;;
            *) # Ignore unknown arguments or model aliases for now to simplify discovery mode. 
               # If we want to support specific models, they can be passed as flags later.
               shift
               ;;
        esac
    done

    # Set environment variables based on GPU mode if USE_AMD is set (passed from caller)
    if [[ "$USE_AMD" == true ]]; then
        export GPU_ENABLE_WGP_MODE=0
        export HIP_VISIBLE_DEVICES=0
    elif [[ "$USE_METAL" == false ]]; then
        export AMD_VULKAN_ICD=RADV
    fi

    local setup_dir
    setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local models_dir="$setup_dir/models"
    local models_preset="$setup_dir/models.ini"
    local runtime_models_preset="${TMPDIR:-/tmp}/nix-llm-models.$$.ini"

    if [[ ! -f "$models_preset" ]]; then
        echo "❌ Missing models preset: $models_preset" >&2
        return 1
    fi

    if [[ ! -d "$models_dir" ]]; then
        echo "❌ Missing models directory: $models_dir" >&2
        echo "Create it and download at least one model listed in $models_preset." >&2
        return 1
    fi

    : > "$runtime_models_preset"

    local current_section=""
    local current_model=""
    local current_mmproj=""
    local valid_model_sections=0
    local -a section_lines=()

    flush_section() {
        if [[ ${#section_lines[@]} -eq 0 ]]; then
            return
        fi

        if [[ -z "$current_section" || "$current_section" == "*" ]]; then
            printf '%s\n' "${section_lines[@]}" >> "$runtime_models_preset"
            return
        fi

        local model_path="$current_model"
        local mmproj_path="$current_mmproj"
        local missing=()

        if [[ -n "$model_path" && "$model_path" != /* ]]; then
            model_path="$setup_dir/${model_path#./}"
        fi
        if [[ -n "$mmproj_path" && "$mmproj_path" != /* ]]; then
            mmproj_path="$setup_dir/${mmproj_path#./}"
        fi

        if [[ -z "$current_model" || ! -f "$model_path" ]]; then
            missing+=("model ($current_model)")
        fi

        if [[ -n "$current_mmproj" && ! -f "$mmproj_path" ]]; then
            missing+=("mmproj ($current_mmproj)")
        fi

        if [[ ${#missing[@]} -eq 0 ]]; then
            printf '%s\n' "${section_lines[@]}" >> "$runtime_models_preset"
            valid_model_sections=$((valid_model_sections + 1))
        else
            echo "Skipping preset [$current_section] due to missing ${missing[*]}" >&2
        fi
    }

    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*\[([^]]+)\][[:space:]]*$ ]]; then
            flush_section
            current_section="${BASH_REMATCH[1]}"
            current_model=""
            current_mmproj=""
            section_lines=("$line")
            continue
        fi

        section_lines+=("$line")

        if [[ "$line" =~ ^[[:space:]]*model[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            current_model="${BASH_REMATCH[1]}"
            current_model="${current_model%%#*}"
            current_model="${current_model#"${current_model%%[![:space:]]*}"}"
            current_model="${current_model%"${current_model##*[![:space:]]}"}"
        elif [[ "$line" =~ ^[[:space:]]*mmproj[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            current_mmproj="${BASH_REMATCH[1]}"
            current_mmproj="${current_mmproj%%#*}"
            current_mmproj="${current_mmproj#"${current_mmproj%%[![:space:]]*}"}"
            current_mmproj="${current_mmproj%"${current_mmproj##*[![:space:]]}"}"
        fi
    done < "$models_preset"
    flush_section

    unset -f flush_section

    if [[ "$valid_model_sections" -eq 0 ]]; then
        echo "❌ No configured model files were found. Download at least one model from readme.md into ./models." >&2
        return 1
    fi

    export LLAMA_ARG_N_PARALLEL=1
    export LLAMA_COMMON_ARGS="--models-dir $models_dir --models-preset $runtime_models_preset --models-max 1"
}