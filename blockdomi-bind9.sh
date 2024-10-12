#!/bin/bash

ensure_directory_exists() {
  local directory="$1"
  if [ ! -d "$directory" ]; then
    mkdir -p "$directory"
    echo -e "\033[0;32mDiretório $directory criado com sucesso.\033[0m"
  else
    echo -e "\033[0;32mDiretório $directory já existe.\033[0m"
  fi
}

download_file() {
  local url="$1"
  local filename="$2"
  curl -s -o "$filename" "$url"
  if [ $? -ne 0 ]; then
    echo "Erro ao baixar arquivo de $url"
    exit 1
  fi
}

get_sequential_number_from_file() {
  local filename="$1"
  cat "$filename" | tr -d '\n' | tr -d '\r'
}

parse_serial() {
  local serial="$1"
  echo "$serial" | awk '{print substr($0, 1, 8) " " substr($0, 9)}'
}

download_and_update_version() {
  local url="$1"
  local file_path="$2"
  local temp_file_path="/tmp/version_temp"

  download_file "$url" "$temp_file_path"
  local new_seq_number=$(get_sequential_number_from_file "$temp_file_path")

  if [ -f "$file_path" ]; then
    local current_seq_number=$(get_sequential_number_from_file "$file_path")
    read new_date new_modifications <<< $(parse_serial "$new_seq_number")
    read current_date current_modifications <<< $(parse_serial "$current_seq_number")

    if [[ "$new_date" > "$current_date" ]] || [[ "$new_date" == "$current_date" && "$new_modifications" -gt "$current_modifications" ]]; then
      echo -e "\033[0;33mAtualizando versão de $current_seq_number para $new_seq_number.\033[0m"
      mv "$temp_file_path" "$file_path"
      return 0
    else
      rm "$temp_file_path"
      echo -e "\033[0;32mJá está na versão mais atual: $current_seq_number.\033[0m"
      return 1
    fi
  else
    echo -e "\033[0;33mVersão local não encontrada, baixando a versão $new_seq_number.\033[0m"
    mv "$temp_file_path" "$file_path"
    return 0
  fi
}

get_serial_number() {
  date +"%Y%m%d01"
}

create_rpz_zone_file() {
  local domain_file="$1"
  local output_file="$2"
  local var_domain="$3"
  local serial_number=$(get_serial_number)

  {
    echo "\$TTL 1H"
    echo "@       IN      SOA LOCALHOST. localhost. ("
    echo "                $serial_number      ; Serial"
    echo "                1h              ; Refresh"
    echo "                15m             ; Retry"
    echo "                30d             ; Expire"
    echo "                2h              ; Negative Cache TTL"
    echo "        )"
    echo "        NS  localhost."
    echo
    while IFS= read -r domain; do
      echo "$domain IN CNAME $var_domain."
      echo "*.$domain IN CNAME $var_domain."
    done < "$domain_file"
  } > "$output_file"
}

reload_bind_service() {
  if named-checkconf; then
    if systemctl reload bind9; then
      echo -e "\033[0;32mServiço Bind9 recarregado com sucesso.\033[0m"
    else
      echo "Erro ao recarregar o serviço Bind9."
    fi
  else
    echo "Erro na configuração do Bind9."
  fi
}

change_permissions() {
  local directory="$1"
  chown bind:bind "$directory" -R
  if [ $? -eq 0 ]; then
    echo -e "\033[0;32mPermissões do diretório alteradas com sucesso.\033[0m"
  else
    echo "Falha ao alterar as permissões do diretório."
  fi
}

main() {
  if [ $# -ne 1 ]; then
    echo "Uso: $0 sub.dominio.com.br"
    exit 1
  fi

  local var_domain="$1"
  local version_url="https://api.blockdomi.com.br/domain/version"
  local domain_list_url="https://api.blockdomi.com.br/domain/all"
  local version_file_path="/etc/bind/rpz/version"
  local domain_list_path="/etc/bind/rpz/domain_all"
  local rpz_zone_file="/etc/bind/rpz/db.rpz.zone.hosts"

  ensure_directory_exists "/etc/bind/rpz"

  if download_and_update_version "$version_url" "$version_file_path"; then
    download_file "$domain_list_url" "$domain_list_path"
    create_rpz_zone_file "$domain_list_path" "$rpz_zone_file" "$var_domain"
    echo -e "\033[0;32mArquivo de zona RPZ atualizado.\033[0m"
    change_permissions "/etc/bind/rpz/"
    reload_bind_service
  fi
}

main "$@"
