package infrastructure

import future.keywords.if

default allow := false

allow if {
    input.disk_free_gb >= data.thresholds.min_disk_free_gb
    input.cpu_load <= data.thresholds.max_cpu_load
}

deny_reasons[msg] if {
    input.disk_free_gb < data.thresholds.min_disk_free_gb
    msg := sprintf("Disk free %.1fGB is below minimum %.1fGB", [input.disk_free_gb, data.thresholds.min_disk_free_gb])
}

deny_reasons[msg] if {
    input.cpu_load > data.thresholds.max_cpu_load
    msg := sprintf("CPU load %.2f exceeds maximum %.2f", [input.cpu_load, data.thresholds.max_cpu_load])
}