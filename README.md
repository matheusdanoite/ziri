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

- `.messages.message` exige 17 propriedades. O compilador é a única
  documentação confiável do contrato — ele lista o que falta e os tipos exatos.
- `reaction` é um **tipo união** (`@UnionValue`), não um opcional.
- `attributes` é `Set`, não `Array`.
- PSK externa no Network.framework só fecha handshake na suíte PSK de TLS 1.2;
  TLS 1.3 com suíte não-PSK falha com -9858.

## Privacidade

O índice fica no aparelho (on-device/PCC). Contém mensagens de terceiros que
não consentiram — o app tem "apagar do índice da Siri" por isso.
