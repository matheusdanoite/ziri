# ziri

Faça a Siri do iPhone responder sobre as suas conversas do WhatsApp — "o que a
Ana falou sobre o orçamento?" — com base no histórico que já está no seu Mac.

Um agente invisível no Mac lê o banco local do WhatsApp para Mac e serve as
mensagens de texto pela rede local. O app do iPhone as recebe e as entrega ao
índice semântico do iOS, onde a Siri as encontra. Quando a Siri cita uma
mensagem, o card mostra o nome e a foto de perfil da conversa, como no WhatsApp.

Nenhum servidor externo, nenhuma conexão com a API do WhatsApp, nenhum risco de
banimento: só leitura do banco que já está no seu Mac, e a conexão entre Mac e
iPhone é cifrada com a chave do pareamento.

## Requisitos

- Mac com **macOS 27** e o **WhatsApp para Mac** (App Store) logado e com o
  histórico sincronizado.
- iPhone com **iOS 27** e Siri com Apple Intelligence, na mesma rede Wi-Fi do Mac.
- **Xcode 27** (App Store), com seu Apple ID em Xcode → Ajustes → Contas. A conta
  gratuita serve.
- iPhone conectado ao Mac por cabo na primeira instalação, com o **Modo de
  Desenvolvedor** ligado (Ajustes → Privacidade e Segurança).

## Instalação

```bash
git clone https://github.com/matheusdanoite/ziri.git
cd ziri
./install.sh
```

O script escolhe o time de assinatura da sua conta, instala o agente no Mac,
compila e instala o app no iPhone e mostra um QR code. Aponte a Câmera do iPhone
para ele e toque em "Abrir no ziri": o app pareia, baixa o histórico e o indexa
para a Siri. A primeira carga leva alguns minutos.

O que o macOS e o iOS vão pedir pelo caminho:

- **Mac:** acesso aos dados de outros apps (o WhatsApp). Se você negar, o script
  abre Ajustes do Sistema em Acesso Total ao Disco; ligue o ziri e rode
  `./install.sh mac`. O ziri também aparece em Itens de Início como item em
  segundo plano — deixe ligado.
- **iPhone:** na primeira vez, confie no desenvolvedor em Ajustes → Geral → VPN e
  Gerenciamento de Dispositivos → seu Apple ID. Depois, permita o acesso à rede
  local quando o ziri pedir.

Depois disso não há nada para abrir: o agente sobe sozinho com o Mac, e o iPhone
sincroniza em segundo plano quando está na mesma rede.

| Comando | Para quê |
| --- | --- |
| `./install.sh` | instalar tudo, ou atualizar depois de um `git pull` |
| `./install.sh iphone` | reinstalar só o app do iPhone |
| `./install.sh mac` | reinstalar só o agente do Mac |
| `./install.sh pair` | mostrar o QR de pareamento de novo |
| `./install.sh uninstall` | remover o ziri do Mac |

### Conta Apple gratuita: renove a cada 7 dias

Apps assinados com conta gratuita param de abrir no iPhone 7 dias depois da
instalação, e o ziri deixa de sincronizar. Para renovar, conecte o iPhone e rode
`./install.sh iphone` — os dados e o pareamento ficam. Com o Apple Developer
Program (pago), a assinatura vale um ano.

## Desinstalar

```bash
./install.sh uninstall
```

Remove o agente e o app do Mac e pergunta se apaga também `~/.ziri` (a cópia
das mensagens e a chave de pareamento). No iPhone, apague o app: o que ele pôs
no índice da Siri vai junto. Para tirar só do índice e manter o app, use
"apagar do índice da Siri" no próprio ziri.

## Como funciona

```
WhatsApp para Mac
  ├─ ChatStorage.sqlite ──VACUUM INTO (somente leitura)──┐
  └─ Media/Profile/*.thumb|.jpg (fotos de perfil) ───────┤
                                                         ▼
                                 agente do ziri.app → ~/.ziri/store.sqlite
                                     (lê a cada pedido) │
                                            Bonjour + TLS 1.2 PSK (_ziri._tcp)
                                                         ▼
                                              app iOS → store local
                                                         │
                                             indexAppEntities(lotes de 500)
                                                         ▼
                                        índice semântico → Siri / Spotlight
```

O resto deste documento é para quem vai mexer no código.

## Desenvolvimento

```
Sources/ZiriCore   leitura do WhatsApp, store, protocolo e servidor de sync (Mac e iPhone)
Sources/ziri       CLI de diagnóstico
ZiriMac            o agente do Mac
ZiriApp            o app do iPhone: sync, entidades do App Intents, indexação
Config             assinatura (ver abaixo)
Tools              gerador do ícone do app do iPhone
```

O `ZiriApp.xcodeproj` é gerado pelo [XcodeGen](https://github.com/yonaskolb/XcodeGen)
a partir do `project.yml` e vai versionado, para quem só instala não precisar
dele. Depois de mudar o `project.yml` ou criar/remover arquivos, rode
`xcodegen generate` e versione o projeto junto.

**Assinatura.** Time e prefixo de bundle id vêm de `Config/Local.xcconfig`, fora
do git, que o `install.sh` cria na primeira vez. O prefixo leva o ID do time
(`fi.ziri.<time>`) porque um bundle id pertence ao primeiro time que o registra.
Mudar o prefixo é, para os dois sistemas, um app novo: o Mac pede de novo o
acesso ao WhatsApp e o iPhone precisa parear e indexar de novo.

```bash
swift test
swift build -c release
.build/release/ziri status     # estado do store + código de pareamento
.build/release/ziri probe      # faz o papel do iPhone contra o agente
.build/release/ziri serve      # o mesmo que o agente, em primeiro plano
```

A CLI roda com a permissão do Terminal para ler o WhatsApp. Com o agente no ar,
`ziri serve` anunciaria um segundo servidor com a mesma chave; pare o agente antes.

### O agente do Mac

Não tem janela, menu nem ícone no Dock. É um agente do launchd embutido no
próprio app (`Contents/Library/LaunchAgents/fi.ziri.mac.agent.plist`), registrado
pelo `SMAppService` quando o app é aberto: sobe ao iniciar sessão e volta
sozinho se cair.

O agente não tem timer: lê o WhatsApp quando o iPhone pede (as leituras sem
mudança nos arquivos do WhatsApp não copiam nada), então o iPhone sempre recebe
o que existe naquele momento e o agente fica parado o resto do tempo.

O mesmo executável tem vários papéis: rodado pelo launchd (`XPC_SERVICE_NAME` é
o label do agente), serve; aberto pela pessoa ou pelo instalador, registra o
agente e sai; com `--pair`, imprime o QR de pareamento; com `--uninstall`, tira o
agente do launchd.

**Por que um app e não o binário `ziri`:** ler o group container do WhatsApp
exige a permissão de dados de outros apps, que o macOS amarra à assinatura. O
binário do `swift build` é assinado ad-hoc e muda de identidade a cada build;
como LaunchAgent, passou a levar `SQLITE_AUTH` (código 23) em toda leitura. O
ziri.app é assinado com "Apple Development" (fixado no `project.yml`, porque o
preset do XcodeGen assina ad-hoc), então a permissão sobrevive a reinstalações.

```bash
launchctl kickstart -k gui/$UID/fi.ziri.mac.agent    # reiniciar
/usr/bin/log stream --predicate 'subsystem == "fi.ziri.mac"'
```

No zsh, `log` sem o caminho é um comando interno do shell e não mostra nada.

### Pareamento

O Mac gera uma chave de 256 bits em `~/.ziri/pairing.key`; ela é a PSK do TLS,
então só quem a tem completa o handshake. O QR carrega `ziri://pair?code=…`, que
a Câmera do iPhone abre no ziri; o app guarda a chave no Keychain. O código
impresso embaixo do QR é a mesma chave, para digitar à mão.

## Por que a Siri do Mac ficou de fora

O macOS 27 tem o mesmo índice semântico, e o ziri já indexou nele. Nada chegava
à Siri: o `SetStoreUpdateService` (Biome) recusa doações de processos cuja
assinatura não é da Apple nem da App Store ("Not trusting process ziri …
validation category 3"). Desenvolvimento (3), Developer ID (6) e ad-hoc (10) são
todos recusados, e `indexAppEntities` não lança erro — o app contava as
mensagens como indexadas. A Siri do iPhone aceita o mesmo código, então o Mac
virou só a fonte.

Para conferir: `/usr/bin/log show --predicate 'process == "SetStoreUpdateService" AND eventMessage CONTAINS "ziri"'`.

## Decisões e armadilhas do schema do WhatsApp

Descobertas medindo o banco real, não documentadas em lugar nenhum:

- **`ZMESSAGETYPE = 0`** é o filtro de "mensagem de texto". `ZGROUPEVENTTYPE = 2`
  é o valor comum de mensagens normais — filtrar por `= 0` descarta ~90% do
  histórico.
- **`ZWAGROUPMEMBER.ZCONTACTNAME` vem vazio em todas as linhas.** O nome do
  participante de grupo sai de `ContactsV2.sqlite` (pelo LID) ou, como fallback
  universal, de `ZWAMESSAGE.ZPUSHNAME`.
- **Os JIDs são `@lid`**, não telefones. `LID.sqlite` existe mas está vazio.
- **Vários campos de nome são string vazia, não NULL** — `COALESCE` puro para na
  string vazia; é preciso `NULLIF(TRIM(x), '')`.
- **`ZSTANZAID`** é a chave estável entre dispositivos. `Z_PK` não é.
- **Fotos de perfil:** `ZWAPROFILEPICTUREITEM` liga cada JID (conversa, grupo,
  participante, canal) a `ZPATH`, relativo ao group container e **sem
  extensão**. No disco o arquivo é `<ZPATH>.thumb` (JPEG 96×96, ~2–3 KB) ou,
  em poucos casos, `<ZPATH>.jpg` (até 640×640). O caminho leva o id da foto,
  então muda quando a foto muda. Linhas sem `Media/Profile/…` são pedidos em
  andamento ou fotos removidas.
- O WAL fica com escritas pendentes: `VACUUM INTO` a partir de conexão
  somente-leitura resolve sem tocar no banco do WhatsApp.

## Decisões do lado da Siri

- `.messages.message` exige 17 propriedades. O compilador é a única
  documentação confiável do contrato — ele lista o que falta e os tipos exatos.
- `reaction` é um **tipo união** (`@UnionValue`), não um opcional.
- `attributes` é `Set`, não `Array`.
- PSK externa no Network.framework só fecha handshake na suíte PSK de TLS 1.2;
  TLS 1.3 com suíte não-PSK falha com -9858.

## O card da Siri

Observado no iOS 27 com a citação de uma mensagem: a Siri usa o **título** e a
**imagem** do `displayRepresentation` da entidade, põe o **ícone do app** como
selo no canto da imagem e **descarta o subtítulo**. Sem imagem, o card mostra o
ícone do app; sem ícone no app, o quadrado em branco do iOS. O título é o nome
da conversa (o de grupo, em grupos); "WhatsApp · data" fica no subtítulo, que
só aparece em outros lugares.

A imagem é a foto de perfil do WhatsApp, que vai em três lugares: na imagem da
mensagem e da conversa, e em `IntentPerson.image` do remetente. Em grupos, a
mensagem leva a foto do grupo e o remetente, a dele. Conversa sem foto usa um
símbolo genérico de conversa. Não é o logo do WhatsApp, que é marca da Meta. As
mensagens que você mandou têm `isMe` e o nome "Você", em vez do "me" que o
store grava.

Como as fotos chegam ao iPhone:

- O agente lê o mapa JID → foto na mesma cópia do banco que já faz para as
  mensagens, e só relê do disco as fotos cujo caminho mudou.
- Só viajam fotos de quem aparece no histórico (~170 de ~620; canais ficam de
  fora), ~650 KB no total. Vão na última página do sync e só quando a versão do
  conjunto (SHA-256 de JID + caminho) difere da que o iPhone mandou no pedido.
- O iPhone substitui o mapa e sabe de quem a foto mudou. O índice guarda o card
  do momento da doação, então as mensagens dessas conversas e remetentes são
  doadas de novo, sem refazer o resto.

**O índice não atualiza sozinho.** Mudar o código do card não muda os cards
já indexados. Toda mudança no que a entidade mostra sobe o `indexVersion` do
`Indexer`, o que zera a marca d'água e reindexa tudo (~15 min para ~35 mil
mensagens num iPhone 15 Pro).

**Ícone.** `Tools/app-icon.swift` gera o ícone do app do iPhone, que também é o
selo do card. Ele é desenhado só com caminhos próprios, porque a licença dos SF
Symbols proíbe usá-los em ícone de app.

```bash
swift Tools/app-icon.swift ZiriApp/Sources/Assets.xcassets/AppIcon.appiconset/icon.png
```

## Tocar na citação da Siri

Abre a conversa de origem no WhatsApp (`OpenZiriMessageIntent`), com limites
que vêm do próprio WhatsApp:

- **Nunca a mensagem exata.** O único deep link público é
  `whatsapp://send?phone=`, que abre a conversa com um número. A análise do
  binário do WhatsApp para Mac (mesmo código do iOS, via Catalyst) confirma: a
  navegação por mensagem existe só por dentro — o visualizador de mídia usa
  `stanza_id` —, sem rota registrada no scheme. `chat_jid` e `message_id` no
  binário são campos de GraphQL (eventos, IA) e de pagamentos, não de URL.
- **1:1 com telefone na agenda** (~81% das mensagens): abre a conversa certa.
  O telefone é resolvido **no toque**: cada resposta de sync traz o mapa
  conversa→telefone completo, lido da agenda do WhatsApp naquele momento
  (`ContactsV2.ZWHATSAPPID` por LID), e o iPhone o guarda em `chat_phone`,
  separado das mensagens. Contato salvo depois passa a valer para o histórico
  inteiro no próximo sync — e funciona offline, porque o mapa já está no iPhone.
- **Grupos e contatos fora da agenda**: só existe LID/JID de grupo, que nenhum
  link público aceita. A citação abre a mensagem no próprio ziri (`ziri://message`).

## Permissão de rede local

Obrigatória nos dois lados, e falha de formas diferentes:

- **iPhone:** `NSBonjourServices` precisa ser **array** no Info.plist. Como
  string, o iOS bloqueia o browse com `NoAuth(-65555)` e nunca mostra o alerta
  de permissão. É por isso que o app usa `ZiriApp/Info.plist` de verdade em vez
  de `INFOPLIST_KEY_*`, que só gera strings.
- **Mac:** um LaunchAgent roda como usuário e está sujeito à privacidade de rede
  local (LaunchDaemons rodando como root, não). O agente só anuncia e escuta, o
  que funciona; se negar, o toggle fica em Ajustes do Sistema → Privacidade e
  Segurança → Rede Local.
- **Terminal:** o Terminal da Apple é código responsável isento; iTerm, VS Code
  e afins precisam da própria autorização para `ziri probe` funcionar.
- O binário da CLI é assinado ad-hoc, então cada `swift build` muda a
  identidade — uma permissão concedida pode não sobreviver a um rebuild. O
  ziri.app não tem esse problema.

## Privacidade

O índice fica no iPhone (on-device/PCC). Contém mensagens de terceiros que
não consentiram — o app tem "apagar do índice da Siri" por isso. As fotos de
perfil seguem o mesmo caminho: copiadas para `~/.ziri/store.sqlite` no Mac e
para o store do app no iPhone, e entram no índice junto com as mensagens. No
Mac, o agente guarda as mensagens normalizadas em `~/.ziri/` (permissões 0700/0600);
na primeira abertura, a versão nova apaga o que a de barra de menus deixou no
índice do Mac e em `~/Library/Application Support/fi.ziri.mac/`.

## Licença e marcas

Código sob a [licença MIT](LICENSE). O ziri não é afiliado, patrocinado nem
aprovado pelo WhatsApp ou pela Meta; WhatsApp é marca da WhatsApp LLC. Siri,
iPhone e macOS são marcas da Apple Inc.
