import os
import requests
import sys
import datetime
import subprocess
from termcolor import colored

def ensure_directory_exists(directory):
    """
    Garante que o diretório exista, criando-o se necessário.
    """
    if not os.path.exists(directory):
        os.makedirs(directory)
        print(colored(f"Diretório {directory} criado com sucesso.", 'green'))
    else:
        print(colored(f"Diretório {directory} já existe.", 'green'))

def download_file(url, filename):
    """
    Baixa um arquivo de uma URL e o salva localmente.
    """
    response = requests.get(url)
    response.raise_for_status()
    with open(filename, 'w') as file:
        file.write(response.text)

def get_sequential_number_from_file(filename):
    """
    Lê um número sequencial de um arquivo de texto.
    """
    with open(filename, 'r') as file:
        return int(file.read().strip())

def download_and_update_version(url, file_path):
    """
    Verifica e atualiza o arquivo de versão se o número de série for diferente.
    Retorna True se o arquivo for atualizado.
    """
    needs_update = False

    # Baixa o número de série da URL
    temp_file_path = '/tmp/version_temp'
    download_file(url, temp_file_path)
    new_seq_number = get_sequential_number_from_file(temp_file_path)

    # Verifica o número de série atual do arquivo local
    if os.path.exists(file_path):
        current_seq_number = get_sequential_number_from_file(file_path)
        if new_seq_number > current_seq_number:
            print(colored(f"Atualizando versão de {current_seq_number} para {new_seq_number}.", 'yellow'))
            os.rename(temp_file_path, file_path)
            needs_update = True
        else:
            os.remove(temp_file_path)
            print(colored(f"Já está na versão mais atual: {current_seq_number}.", 'green'))
    else:
        print(colored(f"Versão local não encontrada, baixando a versão {new_seq_number}.", 'yellow'))
        os.rename(temp_file_path, file_path)
        needs_update = True

    return needs_update


def get_serial_number():
    """
    Gera um número de série baseado na data atual no formato ano-mês-dia-01.
    """
    today = datetime.date.today()
    return today.strftime("%Y%m%d01")

def create_rpz_zone_file(domain_file, output_file, var_domain):
    """
    Cria um arquivo de zona RPZ com base na lista de domínios.
    """
    serial_number = get_serial_number()
    with open(domain_file, 'r') as domains, open(output_file, 'w') as output:
        output.write(f"$TTL 1H\n@       IN      SOA LOCALHOST. {var_domain}. (\n")
        output.write(f"                {serial_number}      ; Serial\n")
        output.write("                1h              ; Refresh\n")
        output.write("                15m             ; Retry\n")
        output.write("                30d             ; Expire\n")
        output.write("                2h              ; Negative Cache TTL\n        )\n")
        output.write(f"        NS  {var_domain}.\n\n")

        for domain in domains:
            domain = domain.strip()
            output.write(f"{domain} IN CNAME .\n")
            output.write(f"*.{domain} IN CNAME .\n")

def reload_unbound_service():
    """
    Recarrega o serviço Unbound somente se a configuração estiver correta.
    """
    try:
        # Verifica se a configuração do Unbound tem erros de sintaxe
        check_result = subprocess.run(['unbound-checkconf'], capture_output=True, text=True)
        if check_result.returncode == 0:  # Sem erros de sintaxe
            # Recarrega o serviço Unbound
            reload_result = subprocess.run(['service', 'unbound', 'reload'], capture_output=True, text=True)
            if reload_result.returncode == 0:
                print(colored("Serviço Unbound recarregado com sucesso.", 'green'))
            else:
                print("Erro ao recarregar o serviço Unbound:")
                print(reload_result.stderr)
        else:
            print("Erro na configuração do Unbound:")
            print(check_result.stderr)
    except subprocess.CalledProcessError as e:
        print(f"Erro ao verificar a configuração do Unbound: {e}")


def change_permissions(directory):
    """
    Altera as permissões de um diretório e seu conteúdo.
    """
    try:
        subprocess.run(['chown', 'unbound:unbound', directory, '-R'], check=True)
        print(colored("Permissões do diretório alteradas com sucesso.", 'green'))
    except subprocess.CalledProcessError as e:
        print(f"Falha ao alterar as permissões do diretório: {e}")

def main(var_domain):
    """
    Executa o script principal: atualiza o arquivo de versão, baixa a lista de domínios e atualiza a zona RPZ se necessário.
    """
    version_url = 'https://api.blockdomi.com.br/domain/version'
    domain_list_url = 'https://api.blockdomi.com.br/domain/all'
    version_file_path = '/etc/unbound/rpz/version'
    domain_list_path = '/etc/unbound/rpz/domain_all'
    rpz_zone_file = '/etc/unbound/rpz/db.rpz.block.zone.hosts'

    # Garante que o diretório /etc/unbound/rpz exista
    ensure_directory_exists('/etc/unbound/rpz')

    # Verifica e atualiza a versão se necessário
    if download_and_update_version(version_url, version_file_path):
        # Baixa a lista de domínios e cria a zona RPZ somente se a versão for atualizada
        download_file(domain_list_url, domain_list_path)
        create_rpz_zone_file(domain_list_path, rpz_zone_file, var_domain)
        print(colored("Arquivo de zona RPZ atualizado.", 'green'))
        change_permissions('/etc/unbound/rpz/')
        reload_unbound_service()  # Recarrega o Unbound se houver uma atualização


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Uso: python3 /etc/unbound/scripts/blockdomi_unbound.py sub.dominio.com.br")
        sys.exit(1)
    main(sys.argv[1])
