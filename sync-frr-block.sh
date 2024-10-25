#!/bin/bash



# Defina as variáveis do community
COMMUNITY="666"

# Cores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # Sem cor

# URLs dos arquivos e versão
IPV4_URL="https://api.blockdomi.com.br/v4/all"
IPV6_URL="https://api.blockdomi.com.br/v6/all"
VERSION_URL="https://api.blockdomi.com.br/domain/version"

# Arquivos locais
IPV4_FILE="/etc/frr/block/ipv4_list.txt"
IPV6_FILE="/etc/frr/block/ipv6_list.txt"
VERSION_FILE="/etc/frr/block/version.txt"

# Verificar se o argumento (ASN) foi fornecido
if [[ -z "$1" ]]; then
    echo -e "${RED}Use: bash /etc/frr/block/script/$(basename "$0") <ASN>${NC}"
    exit 1
fi


# Defina a variável ASN com o valor do argumento
ASN="$1"

# Função para validar se o endereço IPv4 está correto
validate_ip_cidr() {
    local ip_cidr=$1
    # Remove a máscara para exibir apenas o IP
    local ip_address="${ip_cidr%%/*}"
    if [[ $ip_cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]+)?$ ]]; then
        return 0
    else
        echo -e "${RED}Erro: (IPv4) - $ip_address.${NC}"
        return 1
    fi
}

# Função para validar se o endereço IPv6 está correto
validate_ipv6_cidr() {
    local ipv6_cidr=$1
    # Remove a máscara para exibir apenas o IP
    local ipv6_address="${ipv6_cidr%%/*}"
    if [[ $ipv6_cidr =~ ^([0-9a-fA-F:]+(/[0-9]+)?)$ ]]; then
        return 0
    else
        echo -e "${RED}Erro: (IPv6) - $ipv6_address.${NC}"
        return 1
    fi
}
# Função para baixar a versão atual do servidor
get_remote_version() {
    curl -s "$VERSION_URL"
}

# Função para baixar os arquivos de lista
download_files() {
    echo -e "${YELLOW}Baixando listas de IPv4 e IPv6...${NC}"
    curl -s "$IPV4_URL" -o "$IPV4_FILE"
    curl -s "$IPV6_URL" -o "$IPV6_FILE"
    echo -e "${GREEN}Listas baixadas com sucesso.${NC}"
}

# Função para verificar a versão local e a remota
check_versions() {
    # Ler versão local
    if [[ -f "$VERSION_FILE" ]]; then
        local_version=$(cat "$VERSION_FILE")
    else
        local_version="none"
    fi

    # Obter versão remota
    remote_version=$(get_remote_version)

    echo -e "${YELLOW}Versão local: ${NC}$local_version"
    echo -e "${YELLOW}Versão remota: ${NC}$remote_version"

    # Comparar as versões
    if [[ "$local_version" != "$remote_version" ]]; then
        echo -e "${YELLOW}Versão atualizada detectada. Baixando novas listas...${NC}"
        download_files
        echo "$remote_version" > "$VERSION_FILE"  # Atualizar versão local
        run_import_script
    else
        echo -e "${GREEN}As versões são iguais. Nenhuma atualização necessária.${NC}"
    fi
}

# Função para processar as rotas e configurar BGP, prefix-list e route-map
run_import_script() {
    echo -e "${YELLOW}Processando rotas IPv4 e IPv6...${NC}"

    # ----------------------
    # IPv4 Processing Section
    # ----------------------
    echo "Processando rotas IPv4..."

    # Verificar se há IPs no arquivo de IPv4
    if [[ ! -s "$IPV4_FILE" ]]; then
        echo -e "${RED}Erro: Nenhum endereço IPv4 encontrado no arquivo.${NC}"
        IPV4_LIST=()
    else
        mapfile -t IPV4_LIST < "$IPV4_FILE"
    fi

    # Obter a lista atual de redes IPv4 configuradas no BGP, tabela de roteamento, prefix-list e route-map
    BGP_IPV4_NETWORKS=$(vtysh -c "show running-config" | grep -oP '^ network \K([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+')
    ROUTER_IPV4_STATIC_ROUTES=$(vtysh -c "show running-config" | grep -oP '^ip route \K([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+')
    PREFIX_LIST_ENTRIES_IPV4=$(vtysh -c "show running-config" | grep -P '^ip prefix-list EXPORTAR_REDES_V4 seq' | awk '{print $5, $7}')
    ROUTE_MAP_ENTRIES_IPV4=$(vtysh -c "show running-config" | grep -P '^route-map BLACKHOLE_V4 permit' | awk '{print $4}')

    # Converter a lista de IPs IPv4 para o formato esperado (/32 se não houver máscara)
    for i in "${!IPV4_LIST[@]}"; do
        if [[ ! "${IPV4_LIST[$i]}" =~ "/" ]]; then
            IPV4_LIST[$i]="${IPV4_LIST[$i]}/32"
        fi
    done

    # Mapear IPs para seq numbers
    declare -A IPV4_SEQ_MAP

    # Construir mapa atual de seq numbers para IPs na prefix-list
    while read -r SEQ_NUM PREFIX_IP; do
        if [[ -n "$PREFIX_IP" ]]; then
            IPV4_SEQ_MAP["$PREFIX_IP"]=$SEQ_NUM
        fi
    done <<< "$PREFIX_LIST_ENTRIES_IPV4"

    # Encontrar o maior seq_num existente
    max_seq_num_ipv4=0
    for seq in "${IPV4_SEQ_MAP[@]}"; do
        if (( seq > max_seq_num_ipv4 )); then
            max_seq_num_ipv4=$seq
        fi
    done

    # Iniciar seq_num a partir do próximo múltiplo de 10
    seq_num_ipv4=$(( (max_seq_num_ipv4/10 + 1) * 10 ))

    # Remover IPs que não estão mais na lista
    for PREFIX_IP in "${!IPV4_SEQ_MAP[@]}"; do
        if [[ ! " ${IPV4_LIST[@]} " =~ " ${PREFIX_IP} " ]]; then
            SEQ_NUM=${IPV4_SEQ_MAP["$PREFIX_IP"]}

            # Remover prefix-list
            vtysh -c "configure terminal" \
                  -c "no ip prefix-list EXPORTAR_REDES_V4 seq $SEQ_NUM"
            echo "Removido $PREFIX_IP da prefix-list seq $SEQ_NUM (IPv4)."

            # Remover route-map
            vtysh -c "configure terminal" \
                  -c "no route-map BLACKHOLE_V4 permit $SEQ_NUM"
            echo "Removido route-map BLACKHOLE_V4 seq $SEQ_NUM (IPv4)."

            # Remover network do BGP
            vtysh -c "configure terminal" \
                  -c "router bgp $ASN" \
                  -c "no network $PREFIX_IP"
            echo "Removido network $PREFIX_IP do BGP (IPv4)."

            # Remover rota estática
            vtysh -c "configure terminal" \
                  -c "no ip route $PREFIX_IP Null0"

            alteracao_ipv4=true
        fi
    done

    # Adicionar novos IPs
    for IP in "${IPV4_LIST[@]}"; do
        validate_ip_cidr "$IP"
        if [[ $? -eq 0 ]]; then
            if [[ -z "${IPV4_SEQ_MAP["$IP"]}" ]]; then
                # Adicionar prefix-list com seq_num_ipv4
                vtysh -c "configure terminal" \
                      -c "ip prefix-list EXPORTAR_REDES_V4 seq $seq_num_ipv4 permit $IP"
                echo "Adicionado $IP à prefix-list seq $seq_num_ipv4 (IPv4)."

                # Adicionar route-map com o mesmo seq_num_ipv4
                vtysh -c "configure terminal" \
                      -c "route-map BLACKHOLE_V4 permit $seq_num_ipv4" \
                      -c "match ip address prefix-list EXPORTAR_REDES_V4" \
                      -c "set community ${ASN}:${COMMUNITY}"
                echo "Adicionado route-map BLACKHOLE_V4 seq $seq_num_ipv4 (IPv4)."

                # Adicionar network ao BGP
                vtysh -c "configure terminal" \
                      -c "router bgp $ASN" \
                      -c "network $IP"
                echo "Adicionado network $IP ao BGP (IPv4)."

                # Adicionar rota estática
                vtysh -c "configure terminal" \
                      -c "ip route $IP Null0"

                # Atualizar mapa
                IPV4_SEQ_MAP["$IP"]=$seq_num_ipv4
                seq_num_ipv4=$((seq_num_ipv4 + 10))
                alteracao_ipv4=true
            fi
        fi
    done

    if ! $alteracao_ipv4; then
        echo "Nenhuma alteração foi feita nas rotas IPv4."
    fi

    # ----------------------
    # IPv6 Processing Section
    # ----------------------
    echo "Processando rotas IPv6..."

    # Verificar se há IPs no arquivo de IPv6
    if [[ ! -s "$IPV6_FILE" ]]; then
        echo -e "${RED}Erro: Nenhum endereço IPv6 encontrado no arquivo.${NC}"
        IPV6_LIST=()
    else
        mapfile -t IPV6_LIST < "$IPV6_FILE"
    fi

    # Obter a lista atual de redes IPv6 configuradas no BGP, tabela de roteamento, prefix-list e route-map
    BGP_IPV6_NETWORKS=$(vtysh -c "show running-config" | grep -oP '^ network \K([0-9a-fA-F:]+/[0-9]+)')
    ROUTER_IPV6_STATIC_ROUTES=$(vtysh -c "show running-config" | grep -oP '^ipv6 route \K([0-9a-fA-F:]+/[0-9]+)')
    PREFIX_LIST_ENTRIES_IPV6=$(vtysh -c "show running-config" | grep -P '^ipv6 prefix-list EXPORTAR_REDES_V6 seq' | awk '{print $5, $7}')
    ROUTE_MAP_ENTRIES_IPV6=$(vtysh -c "show running-config" | grep -P '^route-map BLACKHOLE_V6 permit' | awk '{print $4}')

    # Converter a lista de IPs IPv6 para o formato esperado (/128 se não houver máscara)
    for i in "${!IPV6_LIST[@]}"; do
        if [[ ! "${IPV6_LIST[$i]}" =~ "/" ]]; then
            IPV6_LIST[$i]="${IPV6_LIST[$i]}/128"
        fi
    done

    # Mapear IPs para seq numbers
    declare -A IPV6_SEQ_MAP

    # Construir mapa atual de seq numbers para IPs na prefix-list
    while read -r SEQ_NUM PREFIX_IP; do
        if [[ -n "$PREFIX_IP" ]]; then
            IPV6_SEQ_MAP["$PREFIX_IP"]=$SEQ_NUM
        fi
    done <<< "$PREFIX_LIST_ENTRIES_IPV6"

    # Encontrar o maior seq_num existente
    max_seq_num_ipv6=0
    for seq in "${IPV6_SEQ_MAP[@]}"; do
        if (( seq > max_seq_num_ipv6 )); then
            max_seq_num_ipv6=$seq
        fi
    done

    # Iniciar seq_num a partir do próximo múltiplo de 10
    seq_num_ipv6=$(( (max_seq_num_ipv6/10 + 1) * 10 ))

    # Remover IPs que não estão mais na lista
    for PREFIX_IP in "${!IPV6_SEQ_MAP[@]}"; do
        if [[ ! " ${IPV6_LIST[@]} " =~ " ${PREFIX_IP} " ]]; then
            SEQ_NUM=${IPV6_SEQ_MAP["$PREFIX_IP"]}

            # Remover prefix-list
            vtysh -c "configure terminal" \
                  -c "no ipv6 prefix-list EXPORTAR_REDES_V6 seq $SEQ_NUM"
            echo "Removido $PREFIX_IP da prefix-list seq $SEQ_NUM (IPv6)."

            # Remover route-map
            vtysh -c "configure terminal" \
                  -c "no route-map BLACKHOLE_V6 permit $SEQ_NUM"
            echo "Removido route-map BLACKHOLE_V6 seq $SEQ_NUM (IPv6)."

            # Remover network do BGP
            vtysh -c "configure terminal" \
                  -c "router bgp $ASN" \
                  -c "address-family ipv6 unicast" \
                  -c "no network $PREFIX_IP"
            echo "Removido network $PREFIX_IP do BGP (IPv6)."

            # Remover rota estática
            vtysh -c "configure terminal" \
                  -c "no ipv6 route $PREFIX_IP Null0"

            alteracao_ipv6=true
        fi
    done

    # Adicionar novos IPs
    for IP in "${IPV6_LIST[@]}"; do
        validate_ipv6_cidr "$IP"
        if [[ $? -eq 0 ]]; then
            if [[ -z "${IPV6_SEQ_MAP["$IP"]}" ]]; then
                # Adicionar prefix-list com seq_num_ipv6
                vtysh -c "configure terminal" \
                      -c "ipv6 prefix-list EXPORTAR_REDES_V6 seq $seq_num_ipv6 permit $IP"
                echo "Adicionado $IP à prefix-list seq $seq_num_ipv6 (IPv6)."

                # Adicionar route-map com o mesmo seq_num_ipv6
                vtysh -c "configure terminal" \
                      -c "route-map BLACKHOLE_V6 permit $seq_num_ipv6" \
                      -c "match ipv6 address prefix-list EXPORTAR_REDES_V6" \
                      -c "set community ${ASN}:${COMMUNITY}"
                echo "Adicionado route-map BLACKHOLE_V6 seq $seq_num_ipv6 (IPv6)."

                # Adicionar network ao BGP
                vtysh -c "configure terminal" \
                      -c "router bgp $ASN" \
                      -c "address-family ipv6 unicast" \
                      -c "network $IP"
                echo "Adicionado network $IP ao BGP (IPv6)."

                # Adicionar rota estática
                vtysh -c "configure terminal" \
                      -c "ipv6 route $IP Null0"

                # Atualizar mapa
                IPV6_SEQ_MAP["$IP"]=$seq_num_ipv6
                seq_num_ipv6=$((seq_num_ipv6 + 10))
                alteracao_ipv6=true
            fi
        fi
    done

    if ! $alteracao_ipv6; then
        echo "Nenhuma alteração foi feita nas rotas IPv6."
    fi

    # Salvar a configuração
    vtysh -c "write memory"

    echo "Configurações IPv4 e IPv6 aplicadas e salvas com sucesso."
}

# Verificar as versões e, se necessário, executar o script de importação
check_versions
