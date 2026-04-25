# TX_DDNS bash completion
# 安装: source 此文件或复制到 /etc/bash_completion.d/

_ddns_completion() {
    local cur prev words cword
    _init_completion || return

    # 命令列表
    local commands="run status test history"

    # 选项列表
    local options="-v --verbose -q --quiet -c --config -V --version -h --help"

    # 根据当前位置补全
    case $prev in
        -c|--config)
            # 补全配置文件路径
            _filedir
            return
            ;;
    esac

    # 如果当前以 - 开头，补全选项
    if [[ $cur == -* ]]; then
        COMPREPLY=($(compgen -W "$options" -- "$cur"))
        return
    fi

    # 否则补全命令
    COMPREPLY=($(compgen -W "$commands $options" -- "$cur"))
}

# 注册补全函数
complete -F _ddns_completion ddnsv2.sh
complete -F _ddns_completion tx-ddns

# 如果脚本被重命名，也可以添加别名
complete -F _ddns_completion ddns 2>/dev/null || true
