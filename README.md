# ziri

Ponte entre o histórico do WhatsApp e o índice semântico da Siri no iOS/macOS 27.

O Mac lê o banco local do WhatsApp, normaliza as mensagens de texto e serve o
delta pela rede local. O iPhone puxa esse delta e o entrega ao índice semântico
do sistema como entidades do schema `messages` — é isso que faz a Siri
responder "o que a Ana falou sobre o orçamento?" com base nas suas conversas.

Nenhum servidor externo, nenhuma conexão com a API do WhatsApp, nenhum risco de
banimento: só leitura do banco que já está no seu Mac.

## Como funciona

```
WhatsApp para Mac
  └─ ChatStorage.sqlite ──VACUUM INTO (somente leitura)──┐
                                                         ▼
                                      ziri ingest → ~/.ziri/store.sqlite
                                                         │
                                            Bonjour + TLS 1.2 PSK (_ziri._tcp)
                                                         ▼
                                              app iOS → store local
                                                         │
                                             indexAppEntities(lotes de 500)
                                                         ▼
                                        índice semântico → Siri / Spotlight
```

## Mac

```bash
swift test                     # busca de telefone no toque, protocolo
swift build -c release
.build/release/ziri extract    # primeira carga
.build/release/ziri status     # estado + código de pareamento
./install-daemon.sh            # daemon: ingere a cada 5 min e serve na LAN
```

`ziri probe` faz o papel do iPhone contra o servidor local, para diagnóstico.

## iPhone

```bash
xcodegen generate
open ZiriApp.xcodeproj
```

Rode no aparelho (o índice semântico não existe no simulador), digite o código
de pareamento que `ziri status` mostra e o app sincroniza e indexa.

## Siri no Mac

O mesmo índice semântico existe no macOS 27, e o ziri para Mac o alimenta com
as conversas do WhatsApp desta máquina. Não há sync: o app lê o banco local do
WhatsApp, guarda em `~/Library/Application Support/fi.ziri.mac/` e indexa aqui.

```bash
./install-mac-app.sh
```

Fica na barra de menus, sem ícone no Dock: mostra quantas mensagens estão na
Siri, indexa de novo a cada 2 minutos (as rodadas sem mudança nos arquivos do
WhatsApp não copiam nada), abre ao iniciar sessão se você quiser e tem o botão
de apagar do índice, que também pausa a indexação.

`Shared/` é o código comum aos dois aparelhos: entidades do App Intents,
indexador, store e o ícone do WhatsApp. Cada aparelho mantém seu próprio índice.

**Instale pelo script, não abra o build direto.** Abrir o app no mesmo instante
em que o LaunchServices o registra (o que acontece com `open` num build recém
compilado, e pode acontecer com o Run do Xcode) faz a auditoria do `linkd` falhar
com `-10814`. O `linkd` não repete essa auditoria sozinho; sem ela o sistema não
tem a metadata do App Intents do app, e cada doação ao índice espera 5 s e volta
vazia. O sintoma é a indexação parecer travada, com o processo ocioso preso em
`__NSXPCCONNECTION_IS_WAITING_FOR_A_SYNCHRONOUS_REPLY__`. O script registra o
app, espera a auditoria terminar e só então o abre.

Para diagnosticar: `/usr/bin/log show --predicate 'process == "linkd" AND eventMessage CONTAINS "fi.ziri.mac"'`.
No zsh, `log` sem o caminho é um comando interno do shell e não mostra nada.

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
- O WAL fica com escritas pendentes: `VACUUM INTO` a partir de conexão
  somente-leitura resolve sem tocar no banco do WhatsApp.

## Decisões do lado da Siri

- A metadata do App Intents vive no `linkd`, alimentada por uma auditoria
  feita quando o app é registrado. Se ela falha, a indexação não dá erro: só
  fica lenta demais para terminar. Ver "Siri no Mac".
- `.messages.message` exige 17 propriedades. O compilador é a única
  documentação confiável do contrato — ele lista o que falta e os tipos exatos.
- `reaction` é um **tipo união** (`@UnionValue`), não um opcional.
- `attributes` é `Set`, não `Array`.
- PSK externa no Network.framework só fecha handshake na suíte PSK de TLS 1.2;
  TLS 1.3 com suíte não-PSK falha com -9858.

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
  local (LaunchDaemons rodando como root, não). O daemon só anuncia e escuta, o
  que funciona; se negar, o toggle fica em Ajustes do Sistema → Privacidade e
  Segurança → Rede Local.
- **Terminal:** o Terminal da Apple é código responsável isento; iTerm, VS Code
  e afins precisam da própria autorização para `ziri probe` funcionar.
- O binário é assinado ad-hoc, então cada `swift build` muda a identidade — uma
  permissão concedida pode não sobreviver a um rebuild.

## Privacidade

O índice fica no aparelho (on-device/PCC). Contém mensagens de terceiros que
não consentiram — o app tem "apagar do índice da Siri" por isso.
