#!/usr/bin/env bash
# gpu-services.sh - Generic GPU service management for multi-stack benchmarking
# Handles dynamic service creation based on --gpu and --combined flags

# Parse GPU specifications and determine service strategy
parse_gpu_config() {
    local gpu_devices="${GPU_DEVICES:-}"
    local combined_devices="${COMBINED_DEVICES:-}"
    
    # Determine mode and device list
    if [ -n "$combined_devices" ]; then
        echo "combined|$combined_devices"
    elif [ -n "$gpu_devices" ]; then
        echo "separate|$gpu_devices"
    else
        # Default: single GPU mode on GPU 0
        echo "separate|0"
    fi
}

# Generate service configurations for GPU setup
# Returns: service_name:port:gpu_spec (one per line)
generate_service_configs() {
    local mode_and_devices
    mode_and_devices="$(parse_gpu_config)"
    
    local mode="${mode_and_devices%%|*}"
    local devices="${mode_and_devices##*|}"
    local base_port="${GPU_SERVICE_BASE_PORT:-11435}"
    
    case "$mode" in
        combined)
            # Single service with all GPUs
            echo "A:$base_port:$devices"
            ;;
        separate)
            # Separate service per GPU
            local port="$base_port"
            local service_letter="A"
            
            IFS=',' read -ra gpu_array <<< "$devices"
            for gpu_id in "${gpu_array[@]}"; do
                gpu_id="$(echo "$gpu_id" | tr -d ' ')"  # trim whitespace
                echo "$service_letter:$port:$gpu_id"
                port=$((port + 1))
                service_letter=$(printf "\\$(printf '%03o' $(($(printf '%d' "'$service_letter") + 1)))")
            done
            ;;
    esac
}

# Create systemd service file for a GPU service
create_gpu_service_file() {
    local service_name="$1"
    local port="$2" 
    local gpu_spec="$3"
    local stack="$4"
    local service_template_func="$5"
    
    # Call stack-specific service template function
    "$service_template_func" "$service_name" "$port" "$gpu_spec"
}

# Setup all GPU services based on configuration
setup_gpu_services() {
    local stack="$1"
    local service_template_func="$2"
    local configs
    
    # Validate GPU configuration is provided
    if [ -z "${GPU_DEVICES:-}${COMBINED_DEVICES:-}" ]; then
        warn "GPU configuration required. Use --gpu X or --combined X,Y,Z flags."
        return 1
    fi
    
    info "Setting up GPU services for $stack"
    
    # Get service configurations
    configs="$(generate_service_configs)"
    
    if [ -z "$configs" ]; then
        warn "No GPU service configurations generated"
        return 1
    fi
    
    # Create each service
    while IFS=':' read -r service_letter port gpu_spec; do
        local service_name="${stack}-test-${service_letter,,}.service"  # lowercase
        info "Creating $service_name (port $port, GPU $gpu_spec)"
        
        create_gpu_service_file "$service_name" "$port" "$gpu_spec" "$stack" "$service_template_func"
        
        # Enable and start the service
        systemctl daemon-reload
        systemctl enable "$service_name"
        systemctl restart "$service_name"
        # Wait for the service to be ready
        if wait_for_service_ready "$service_name"; then
            ok "$service_name ready on port $port"
        else
            error "$service_name failed to start. Check logs with: journalctl -u $service_name"
            return 1
        fi
    done
}

# Wait for a systemd service to report it is ready
wait_for_service_ready() {
    local service_name="$1"
    local attempts=10
    local delay=2
    
    for ((i=0; i<attempts; i++)); do
        if systemctl is-active --quiet "$service_name"; then
            return 0
        fi
        sleep "$delay"
    done
    
    return 1
}

# Setup all GPU services based on configuration
setup_gpu_services() {
    local stack="$1"
    local service_template_func="$2"
    local configs
    
    # Validate GPU configuration is provided
    if [ -z "${GPU_DEVICES:-}${COMBINED_DEVICES:-}" ]; then
        warn "GPU configuration required. Use --gpu X or --combined X,Y,Z flags."
        return 1
    fi
    
    info "Setting up GPU services for $stack"
    
    # Get service configurations
    configs="$(generate_service_configs)"
    
    if [ -z "$configs" ]; then
        warn "No GPU service configurations generated"
        return 1
    fi
    
    # Create each service
    while IFS=':' read -r service_letter port gpu_spec; do
        local service_name="${stack}-test-${service_letter,,}.service"  # lowercase
        info "Creating $service_name (port $port, GPU $gpu_spec)"
        
        create_gpu_service_file "$service_name" "$port" "$gpu_spec" "$stack" "$service_template_func"
        
        # Enable and start the service (with sudo if needed)
        if [ "$(id -u)" -ne 0 ]; then
            sudo systemctl daemon-reload
            sudo systemctl enable "$service_name"
            sudo systemctl start "$service_name"
        else
            systemctl daemon-reload
            systemctl enable "$service_name"
            systemctl start "$service_name"
        fi
        
        # Wait for service to be ready
        local max_wait=30
        local wait_count=0
        while [ $wait_count -lt $max_wait ]; do
            if curl -sf "http://127.0.0.1:$port/api/tags" >/dev/null 2>&1; then
                ok "$service_name ready on port $port"
                break
            fi
            sleep 1
            wait_count=$((wait_count + 1))
        done
        
        if [ $wait_count -ge $max_wait ]; then
            warn "$service_name failed to start on port $port"
        fi
        
    done <<< "$configs"
}

# Cleanup all GPU services for a stack
cleanup_gpu_services() {
    local stack="$1"
    
    info "Cleaning up GPU services for $stack"
    
    # Stop and disable all test services for this stack
    for service_file in /etc/systemd/system/${stack}-test-*.service; do
        if [ -f "$service_file" ]; then
            local service_name="$(basename "$service_file")"
            if [ "$(id -u)" -ne 0 ]; then
                sudo systemctl stop "$service_name" 2>/dev/null || true
                sudo systemctl disable "$service_name" 2>/dev/null || true
                sudo rm -f "$service_file"
            else
                systemctl stop "$service_name" 2>/dev/null || true
                systemctl disable "$service_name" 2>/dev/null || true
                rm -f "$service_file"
            fi
            ok "Removed $service_name"
        fi
    done
    
    if [ "$(id -u)" -ne 0 ]; then
        sudo systemctl daemon-reload
    else
        systemctl daemon-reload
    fi
}

# Get list of active GPU service endpoints for a stack
# Returns: endpoint|gpu_index
get_gpu_service_endpoints() {
    local stack="$1"
    
    # Check which services are active for this stack
    for service_file in /etc/systemd/system/${stack}-test-*.service; do
        if [ -f "$service_file" ]; then
            local service_name="$(basename "$service_file")"
            if systemctl is-active "$service_name" >/dev/null 2>&1; then
                # Extract port and GPU index from service environment
                local envs
                envs="$(systemctl show "$service_name" --property=Environment)"
                local service_port
                service_port="$(echo "$envs" | sed -n 's/.*OLLAMA_HOST=[^:]*:\([0-9]*\).*/\1/p')"
                local gpu_index
                gpu_index="$(echo "$envs" | sed -n 's/.*CUDA_VISIBLE_DEVICES=\([0-9,]*\).*/\1/p')"
                
                if [ -n "$service_port" ] && [ -n "$gpu_index" ]; then
                    echo "127.0.0.1:$service_port|$gpu_index"
                fi
            fi
        fi
    done
}