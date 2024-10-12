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

create_rpz_zone_file() {
  local domain_file="$1"
  local output_file="$2"
  local var_domain="$3"

  {
    while IFS= read -r domain; do
      echo "local-zone: \"$domain\" redirect"
      if [[ "$var_domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "local-data: \"$domain A $var_domain\""
      elif [[ "$var_domain" =~ ^[a-fA-F0-9:]+$ ]]; then
        echo "local-data: \"$domain AAAA $var_domain\""
      else
        echo "local-data: \"$domain CNAME $var_domain\""
      fi
    done < "$domain_file"
  } > "$output_file"
}

reload_unbound_service() {
  if unbound-checkconf; then
    if systemctl reload unbound; then
      echo -e "\033[0;32mServiço Unbound recarregado com sucesso.\033[0m"
    else
      echo "Erro ao recarregar o serviço Unbound."
    fi
  else
    echo "Erro na configuração do Unbound."
  fi
}

change_permissions() {
  local directory="$1"
  chown unbound:unbound "$directory" -R
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
  local version_file_path="/etc/unbound/blockdomi/version"
  local domain_list_path="/etc/unbound/blockdomi/domain_all"
  local rpz_zone_file="/etc/unbound/blockdomi/blockdomi.conf"

  ensure_directory_exists "/etc/unbound/blockdomi"

  if download_and_update_version "$version_url" "$version_file_path"; then
    download_file "$domain_list_url" "$domain_list_path"
    create_rpz_zone_file "$domain_list_path" "$rpz_zone_file" "$var_domain"
    echo -e "\033[0;32mArquivo de configuração do Unbound atualizado para bloqueio.\033[0m"
    change_permissions "/etc/unbound/blockdomi"
    reload_unbound_service
  fi
}

main "$@"
