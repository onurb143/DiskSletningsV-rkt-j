#!/bin/bash

# Funktion: Log fejl og information til en logfil
log_file="/var/log/disk_wipe.log"
log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$log_file"
}

# Find bootdisken
boot_disk=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//')
log "Bootdisken er identificeret som $boot_disk. Denne disk vil ikke blive vist som en mulighed for sletning."

# Find og vis tilgængelige diske undtagen bootdisken
log "Finder tilgængelige diske (ekskluderer bootdisken)..."
echo "Tilgængelige diske:"
lsblk -ndo NAME,SIZE,MODEL,SERIAL | grep -v "$(basename "$boot_disk")"

# Brugeren vælger en disk
read -p "Vælg disk (indtast diskens navn, f.eks. sdb): " selected_disk
disk_path="/dev/$selected_disk"

# Kontrollér, om disken findes og ikke er bootdisken
if [[ "$disk_path" == "$boot_disk" ]]; then
    log "Valgt disk er bootdisken ($disk_path), og kan ikke slettes."
    echo "Du kan ikke slette bootdisken ($disk_path). Vælg en anden disk."
    exit 1
fi

if [[ ! -b "$disk_path" ]]; then
    log "Disken $disk_path blev ikke fundet."
    echo "Disken $disk_path blev ikke fundet. Kontrollér valget og prøv igen."
    exit 1
fi

# Prøv at aflæse oplysninger med smartctl
log "Aflæser diskoplysninger for $disk_path..."
smartctl_info=$(smartctl -i "$disk_path" || smartctl -d sat -i "$disk_path")
if [[ -z "$smartctl_info" ]]; then
    log "Kunne ikke aflæse diskoplysninger for $disk_path."
    echo "Kunne ikke aflæse diskoplysninger. Kontrollér disken."
    exit 1
fi
log "Diskoplysninger aflæst."

# Ekstraher diskoplysninger med fallback-værdier
serial_number=$(echo "$smartctl_info" | grep "Serial Number" | awk -F: '{print $2}' | xargs)
serial_number=${serial_number:-"UNKNOWN"}

manufacturer=$(lsblk -no VENDOR "$disk_path" | xargs)
manufacturer=${manufacturer:-"UNKNOWN"}

capacity=$(lsblk -bno SIZE "$disk_path" | awk '{print $1 / 1024 / 1024 / 1024}' | cut -d. -f1)
disk_type=$(echo "$smartctl_info" | grep "Rotation Rate" | grep -q "Solid State" && echo "SSD" || echo "HDD")

# Kontroller, om disken allerede findes i databasen
log "Kontrollerer, om disken allerede findes i databasen..."
DISK_API="http://192.168.32.15:5002/api/disks"
disk_check_response=$(curl -s -X GET "$DISK_API?serialNumber=$serial_number")

if [[ "$disk_check_response" == *"$serial_number"* ]]; then
    log "Disken med serienummer $serial_number findes allerede i databasen. Ingen tilføjelse nødvendig."
else
    # Tilføj disken til databasen
    log "Tilføjer disken til databasen..."
    disk_payload=$(jq -n \
        --arg serialNumber "$serial_number" \
        --argjson capacity "$capacity" \
        --arg type "$disk_type" \
        --arg manufacturer "$manufacturer" \
        --arg path "$disk_path" \
        --arg status "Available" \
        '{SerialNumber: $serialNumber, Capacity: $capacity, Type: $type, Manufacturer: $manufacturer, Path: $path, Status: $status}')

    disk_response=$(curl -s -w "\n%{http_code}" -X POST "$DISK_API" -H "Content-Type: application/json" -d "$disk_payload")
    disk_http_status=$(echo "$disk_response" | tail -n1)

    if [[ "$disk_http_status" -ne 200 && "$disk_http_status" -ne 201 ]]; then
        log "Fejl ved tilføjelse af disken til databasen. HTTP status: $disk_http_status."
        echo "Fejl ved tilføjelse af disken til databasen."
        exit 1
    fi
    log "Disken blev tilføjet til databasen med succes."
fi

# Udskriv diskoplysninger
echo "Diskinformationer fundet:"
echo "Sti: $disk_path"
echo "Serienummer: $serial_number"
echo "Kapacitet: ${capacity} GB"
echo "Type: $disk_type"
echo "Producent: $manufacturer"

# Vælg slettemetode
echo "Tilgængelige slettemetoder:"
wipe_methods=$(curl -s http://192.168.32.15:5002/api/wipeMethods)
if [[ -z "$wipe_methods" ]]; then
    log "Kunne ikke hente slettemetoder fra API."
    echo "Kunne ikke hente slettemetoder fra API. Kontrollér forbindelsen."
    exit 1
fi
echo "$wipe_methods" | jq -r '.[] | "\(.wipeMethodID): \(.name) - \(.description)"'

read -p "Vælg slettemetode (indtast ID): " selected_method
method=$(echo "$wipe_methods" | jq -e ".[] | select(.wipeMethodID == $selected_method)")

method_name=$(echo "$method" | jq -r '.name')

read -p "Vil du slette disken $disk_path med $method_name? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
    log "Sletning annulleret af brugeren."
    echo "Sletning annulleret."
    exit 0
fi

# Registrer starttidspunkt
start_time=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
log "Sletning af $disk_path med $method_name startet kl. $start_time"

# Udfør sletning baseret på valgt metode
echo "Sletter data på $disk_path med metode $method_name..."
case $selected_method in
    1) hdparm --user-master u --security-set-pass p "$disk_path" && hdparm --user-master u --security-erase p "$disk_path" ;;
    2) dd if=/dev/zero of="$disk_path" bs=1M status=progress ;;
    3) dd if=/dev/urandom of="$disk_path" bs=1M status=progress ;;
    4) shred -n 35 -v "$disk_path" ;;
    5) shred -n 3 -v "$disk_path" ;;
    6) shred -n 1 -z -v "$disk_path" ;;
    7) shred -n 7 -v "$disk_path" ;; # Schneier Method
    8) shred -n 3 -v "$disk_path" ;; # HMG IS5 (Enhanced)
    9) shred -n 35 -v "$disk_path" ;; # Peter Gutmann's Method
    10) dd if=/dev/zero of="$disk_path" bs=1M status=progress ;; # Single Pass Zeroing
    11) shred -n 4 -v "$disk_path" ;; # DoD 5220.22-M (E)
    12) dd if=/dev/zero of="$disk_path" bs=1M status=progress ;; # ISO/IEC 27040
    *) log "Slettemetoden er ikke implementeret."; exit 1 ;;
esac

# Registrer sluttidspunkt
end_time=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
log "Sletning fuldført for $disk_path med $method_name kl. $end_time"

# Generer og send sletterapport
wipe_report=$(jq -n \
    --arg startTime "$start_time" \
    --arg endTime "$end_time" \
    --arg status "Completed" \
    --arg diskType "$disk_type" \
    --argjson capacity "$capacity" \
    --arg serialNumber "$serial_number" \
    --arg manufacturer "$manufacturer" \
    --arg wipeMethodName "$method_name" \
    '{startTime: $startTime, endTime: $endTime, status: $status, diskType: $diskType, capacity: $capacity, serialNumber: $serialNumber, manufacturer: $manufacturer, wipeMethodName: $wipeMethodName}')
    
    REPORT_API="http://192.168.32.15:5002/api/wipeReports"
response=$(curl -s -w "\n%{http_code}" -X POST "$REPORT_API" -H "Content-Type: application/json" -d "$wipe_report")

http_status=$(echo "$response" | tail -n1)
server_response=$(echo "$response" | head -n -1)

echo "Server Response: $server_response"

if [[ "$http_status" -ne 200 && "$http_status" -ne 201 ]]; then
    log "Fejl ved afsendelse af sletterapport. HTTP status: $http_status."
    echo "Fejl ved afsendelse af sletterapport."
else
    log "Sletterapport sendt med succes."
    echo "Sletterapport sendt med succes!"
fi

exit 0
