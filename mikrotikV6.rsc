/log warning "Iniciando limpeza de DNS Static"
/system logging disable [find topics~"info"]
/ip dns static remove [find]
/system logging enable [find topics~"info"]
/log warning "Limpeza de DNS Static concluida"

/tool fetch url="https://api.blockdomi.com.br/commands/mikrotik/v6" mode=http dst-path=blocked_domains.rsc

/log warning "Iniciando importacao de dominios bloqueados"
/system logging disable [find topics~"info"]
/import file-name=blocked_domains.rsc
/system logging enable [find topics~"info"]
/log warning "Importacao de dominios bloqueados concluida"

/file remove blocked_domains.rsc
