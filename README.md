# macfast

Aplicativo de performance para macOS. Desativa recursos que consomem CPU, GPU e disco
sem entregar muito em troca — com atenção especial a Macs rodando via
**OpenCore Legacy Patcher (OCLP)**, onde transparência, animações e análise de mídia em
segundo plano pesam bem mais do que num Mac suportado.

Todo ajuste é **reversível**: antes da primeira alteração o MacFast grava o valor original
de cada chave e o restaura no `revert` — inclusive se você já tinha personalizado o sistema.

## O que ele não faz

O MacFast **nunca** desativa SIP, Gatekeeper, XProtect, FileVault ou assinatura de código.
Isso não deixa o Mac mais rápido, e em máquinas com OCLP mexer no SIP por fora atrapalha o
root patching do próprio OCLP. Ele também não toca em nada que o OCLP gerencia
(kexts, patches de root, `/System/Library`).

## Requisitos

- macOS 11 Big Sur ou mais recente
- Xcode Command Line Tools (para compilar)

## Instalação

```sh
git clone https://github.com/m4ndr4k3s/macfast.git
cd macfast
./scripts/build-app.sh
```

Isso gera `build/MacFast.app` (interface gráfica) e `build/macfast` (linha de comando).

## Uso — interface

Abra o `MacFast.app`. A tela inicial traz três presets:

| Preset | O que aplica |
| --- | --- |
| **Conservador** | Só ajustes visuais. Nenhum recurso deixa de funcionar. |
| **Recomendado** | Ganho perceptível, trocando recursos que a maioria não usa. |
| **OCLP** | Foco no que mais pesa em Macs sem suporte gráfico nativo. |

Cada ajuste mostra o que faz e **do que você abre mão**, além de um selo de risco
(Seguro / Moderado / Avançado). Quando o OCLP é detectado, o app avisa na tela inicial.

Ajustes que precisam de root abrem o diálogo padrão de senha do macOS.

## Uso — linha de comando

```sh
macfast list                # lista os ajustes, agrupados por categoria
macfast list privacy        # só uma categoria
macfast list --oclp         # só os que rendem mais em Macs com OCLP
macfast status              # estado atual de cada ajuste
macfast presets             # presets disponíveis
macfast info                # macOS, modelo e detecção de OCLP
```

Ligar e desligar, item a item ou em lote:

```sh
macfast disable airdrop airplay-receiver   # desativa só esses dois
macfast enable airdrop                     # reativa só esse
macfast disable oclp                       # um preset inteiro
macfast enable --all                       # reativa tudo que foi desativado
```

`apply` e `revert` continuam funcionando como sinônimos de `disable` e `enable`.
Categorias válidas: `interface`, `animations`, `indexing`, `background`, `power`,
`network`, `privacy`, `notifications`, `battery`, `trackpad`.

Antes de aplicar qualquer coisa, vale conferir o que será executado:

```sh
macfast --dry-run apply oclp
```

O `--dry-run` imprime os comandos exatos e não altera nada.

## O que pode ser desativado

| Categoria | Exemplos |
| --- | --- |
| Interface | transparência/desfoque, tingimento pelo papel de parede, Stage Manager, reabrir janelas ao ligar |
| Animações | abrir/redimensionar janelas, Mission Control, Finder, Launchpad, Dock, rolagem suave |
| Indexação | indexação do Spotlight, sugestões da Siri na busca |
| Segundo plano | Siri, análise de mídia (Texto ao Vivo), análise da Fototeca, sugestões proativas, Game Center, abrir Fotos ao conectar câmera |
| Energia e disco | imagem de hibernação, Power Nap, sensor de movimento, backup automático do Time Machine |
| Rede | Handoff, AirDrop, Receptor AirPlay, Bonjour, assistente de Wi-Fi, `.DS_Store` em rede, Controle Universal, sharingd |
| Privacidade | anúncios personalizados, gravações da Siri, sugestões do Safari, janela de relatório de falha, envio de diagnósticos |
| Notificações | duração dos banners, Dicas do macOS, busca automática por atualizações, Central de Notificações |
| Bateria | acordar por aproximação, acordar por rede, sessão de terminal, rede durante o sono |
| Trackpad e teclado | Force Touch, gestos de Launchpad e Mesa, correção automática, repetição de teclas, Ditado |

### Compatibilidade por versão

Cada ajuste declara em quais versões do macOS ele realmente faz efeito. Isso importa
porque um `defaults write` de uma chave que o sistema não conhece **não dá erro** — ele
grava e não acontece nada. Sem essa marcação, o ajuste se diria aplicado sem ter feito
nada.

Ajustes fora da faixa aparecem como **Indisponível nesta versão**, com o interruptor
desligado e a exigência escrita ao lado (por exemplo, `macOS 13+` para o Stage Manager).
No terminal eles aparecem com `[-]` no `status` e com o selo de versão no `list`. Os
presets já ignoram automaticamente o que sua versão não suporta.

Eles ficam visíveis de propósito: saber que o ajuste existe mas não vale para o seu
sistema é melhor do que ele simplesmente sumir da lista.

Cada ajuste é independente: nada obriga a usar preset. Na interface é um interruptor
por linha; no terminal, `macfast disable <id>` e `macfast enable <id>`. O estado
mostrado vem sempre do sistema, não de um registro interno do app — se você mudar
algo pelas Ajustes do Sistema, o MacFast reflete a mudança.

Em Macs com OCLP, os dois que mais mudam a sensação de velocidade são
**reduzir transparência** e **reduzir movimento**.

## Como reverter

Pela interface: **Reverter tudo ao estado original**.
Pelo terminal: `macfast revert --all`, ou `macfast revert <id>` para um ajuste específico.

Os valores originais ficam em `~/Library/Application Support/MacFast/backups.json`.
Apagar esse arquivo faz o MacFast perder a memória do que existia antes — o `revert`
passa a remover a chave e deixar o macOS voltar ao padrão de fábrica.

## Desenvolvimento

```sh
swift build
swift test
```

O motor, o CLI e os testes só usam Foundation, então compilam também em Linux — o
alvo da interface só é declarado quando o pacote é montado a partir do macOS. É por
isso que `swift test` funciona nos dois lugares.

A interface, essa só compila num macOS de verdade: SwiftUI e AppKit vêm do SDK da
Apple. O CI (`.github/workflows/ci.yml`) cobre os dois casos — o núcleo em Linux, e o
app completo num runner macOS, que ainda monta o `MacFast.app` e publica como artefato
do build.

O motor (`MacFastKit`) não depende de interface, então os testes rodam sem tocar no sistema:
usam um executor falso que apenas registra os comandos. Os testes também protegem o catálogo —
todo ajuste precisa declarar do que se abre mão, ter reversão e saber ler o próprio estado,
e nenhum comando pode mexer na segurança do sistema.

Estrutura:

- `Sources/MacFastKit` — catálogo, motor de aplicação/reversão, backup, detecção de OCLP
- `Sources/MacFastApp` — interface SwiftUI
- `Sources/macfastcli` — comando `macfast`

Para adicionar um ajuste, basta descrevê-lo em `Sources/MacFastKit/TweakCatalog.swift`;
a interface e o CLI o exibem automaticamente.

## Licença

MIT — veja [LICENSE](LICENSE).
