#!/bin/bash

# Funktion: Log fejl og information til en logfil
log_file="/var/log/disk_wipe.log"
log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$log_file"
}

# Find og vis tilgængelige diske
log "Finder tilgængelige diske..."
echo "Tilgængelige diske:"
lsblk -do NAME,SIZE,MODEL,SERIAL,VENDOR

# Brugeren vælger en disk
read -p "Vælg disk (indtast diskens navn, f.eks. sda): " selected_disk
disk_path="/dev/$selected_disk"

# Kontrollér, om disken findes
if [[ ! -b "$disk_path" ]]; then
    log "Disken $disk_path blev ikke fundet."
    echo "Disken $disk_path blev ikke fundet. Kontrollér valget og prøv igen."
    exit 1
fi

# Prøv at aflæse oplysninger med smartctl
log "Aflæser diskoplysninger for $disk_path..."
smartctl_info=$(smartctl -i "$disk_path" || smartctl -d sat -i "$disk_path" || smartctl -d usbjmicron,0 -i "$disk_path" || smartctl -d usbjmicron,1 -i "$disk_path")
if [[ -z "$smartctl_info" ]]; then
    log "Kunne ikke aflæse diskoplysninger for $disk_path."
    echo "Kunne ikke aflæse diskoplysninger. Kontrollér disken."
    exit 1
fi
log "Diskoplysninger aflæst."

# Ekstraher diskoplysninger
serial_number=$(echo "$smartctl_info" | grep "Serial Number" | awk -F: '{print $2}' | xargs)
model=$(echo "$smartctl_info" | grep "Device Model" | awk -F: '{print $2}' | xargs)
manufacturer=$(lsblk -no VENDOR "$disk_path" | xargs)
capacity=$(echo "$smartctl_info" | grep "User Capacity" | awk -F: '{print $2}' | awk '{print $1}' | tr -d ',' | xargs)
disk_type=$(echo "$smartctl_info" | grep "Rotation Rate" | grep -q "Solid State" && echo "SSD" || echo "HDD")

# Hvis det er en USB-disk, forsøg at aflæse yderligere oplysninger fra lsblk
if [[ -z "$serial_number" ]]; then
    serial_number=$(lsblk -no SERIAL "$disk_path")
fi

if [[ -z "$model" ]]; then
    model=$(lsblk -no MODEL "$disk_path")
fi

if [[ -z "$manufacturer" ]]; then
    manufacturer=$(lsblk -no VENDOR "$disk_path")
fi

if [[ -z "$capacity" ]]; then
    capacity=$(lsblk -bno SIZE "$disk_path" | awk '{print $1 / 1024 / 1024 / 1024}' | cut -d. -f1)
else
    capacity=$(echo "$capacity" | awk '{print $1 / (1024 * 1024 * 1024)}' | cut -d. -f1)
fi

if [[ -z "$disk_type" ]]; then
    disk_type="USB"
fi

# Valider aflæsning af data
if [[ -z "$serial_number" || -z "$model" || -z "$capacity" || -z "$disk_type" || -z "$manufacturer" ]]; then
    log "Kunne ikke aflæse alle nødvendige oplysninger fra disken."
    echo "Kunne ikke aflæse alle nødvendige oplysninger fra disken. Kontrollér værktøjerne."
    exit 1
fi

# Udskriv diskoplysninger
echo "Diskinformationer fundet:"
echo "Sti: $disk_path"
echo "Model: $model"
echo "Serienummer: $serial_number"
echo "Kapacitet: ${capacity} GB"
echo "Type: $disk_type"
echo "Producent: $manufacturer"

# Send diskoplysninger til API
disk_data=$(jq -n \
    --arg type "$disk_type" \
    --arg path "$disk_path" \
    --arg serialNumber "$serial_number" \
    --arg model "$model" \
    --arg manufacturer "$manufacturer" \
    --argjson capacity "$capacity" \
    '{type: $type, path: $path, serialNumber: $serialNumber, model: $model, manufacturer: $manufacturer, capacity: $capacity}')

echo "Debug Disk Data JSON: $disk_data"

DISK_API="http://192.168.32.15:5002/api/disks"
disk_response=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$DISK_API" \
    -H "Content-Type: application/json" \
    -d "$disk_data")

if [[ "$disk_response" -ne 200 && "$disk_response" -ne 201 ]]; then
    log "Fejl ved registrering af disk. HTTP status: $disk_response."
    echo "Fejl ved registrering af disk. HTTP status: $disk_response."
    exit 1
else
    log "Diskdata sendt til API med succes."
    echo "Diskdata sendt til API med succes!"
fi

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
method_overwrite_passes=$(echo "$method" | jq -r '.overwritePass')

read -p "Vil du slette disken $disk_path med $method_name? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
    log "Sletning annulleret af brugeren."
    echo "Sletning annulleret."
    exit 0
fi

# Udfør sletning baseret på valgt metode
echo "Sletter data på $disk_path med metode $method_name..."
log "Starter sletning af $disk_path med metode $method_name."
case $selected_method in
    1)
        hdparm --user-master u --security-set-pass p "$disk_path"
        hdparm --user-master u --security-erase p "$disk_path"
        ;;
    2)
        dd if=/dev/zero of="$disk_path" bs=1M status=progress
        ;;
    3)
        dd if=/dev/urandom of="$disk_path" bs=1M status=progress
        ;;
    5)
        shred -n 3 -v "$disk_path"
        ;;
    6)
        shred -n 1 -z -v "$disk_path"
        ;;
    *)
        log "Ugyldig eller ikke-implementeret slettemetode valgt."
        echo "Slettemetoden er endnu ikke implementeret."
        exit 1
        ;;
esac

# Generer og send sletterapport
wipe_report=$(jq -n \
    --argjson wipeJobId 0 \
    --arg startTime "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg endTime "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg status "Completed" \
    --arg diskType "$disk_type" \
    --argjson capacity "$capacity" \
    --arg serialNumber "$serial_number" \
    --arg manufacturer "$manufacturer" \
    --arg wipeMethodName "$method_name" \
    --argjson overwritePasses "$method_overwrite_passes" \
    --arg performedBy "default-user-id" \
    '{wipeJobId: $wipeJobId, startTime: $startTime, endTime: $endTime, status: $status, diskType: $diskType, capacity: $capacity, serialNumber: $serialNumber, manufacturer: $manufacturer, wipeMethodName: $wipeMethodName, overwritePasses: $overwritePasses, performedBy: $performedBy}')

echo "Debug Wipe Report JSON: $wipe_report"

REPORT_API="http://192.168.32.15:5002/api/wipeReports"
response=$(curl -s -w "\n%{http_code}" -X POST "$REPORT_API" \
    -H "Content-Type: application/json" \
    -d "$wipe_report")

# Opdel responsen i body og HTTP-statuskode
http_status=$(echo "$response" | tail -n1)
server_response=$(echo "$response" | head -n -1)

echo "Server Response: $server_response"

if [[ "$http_status" -ne 200 && "$http_status" -ne 201 ]]; then
    log "Fejl ved afsendelse af sletterapport. HTTP status: $http_status. Respons: $server_response"
    echo "Fejl ved afsendelse af sletterapport. HTTP status: $http_status. Respons: $server_response"
else
    log "Sletterapport sendt med succes: $server_response"
    echo "Sletterapport sendt med succes!"
fi
