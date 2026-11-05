# Contribuindo com o MacRar

Obrigado por ajudar a melhorar o app. Antes de implementar mudanças grandes, abra uma issue para alinhar o problema e a proposta. Siga o [código de conduta](CODE_OF_CONDUCT.md).

## Ambiente

- macOS 13 ou superior.
- Xcode ou Command Line Tools com Swift 6.
- Python 3 para os testes de integração do mecanismo C.

```sh
git clone https://github.com/rafaelbazzolini/mac-rar.git
cd mac-rar
./scripts/build-app.sh
open dist/MacRar.app
```

Não são necessários Homebrew, serviços externos nem pacotes Swift de terceiros para compilar o app.

## Verificação

```sh
swift test --build-system native --disable-sandbox
python3 scripts/test-extraction.py
python3 scripts/test-compression.py
```

O teste de abertura real pelo Finder encerra instâncias deste bundle, altera temporariamente duas preferências, restaura seus valores e deixa o app aberto:

```sh
swift scripts/test-finder-open.swift "$PWD/dist/MacRar.app"
```

Para gerar a captura de configurações do README, em uma sessão gráfica local:

```sh
MACRAR_SCREENSHOT_DIR="$PWD/docs/images" \
  swift test --build-system native --disable-sandbox --filter DocumentationScreenshots
```

A captura de configurações usa a renderização da própria view AppKit/SwiftUI, sem capturar a tela inteira. Ela não é executada por padrão no CI. Confira visualmente o resultado antes de incluí-lo no commit. A ilustração de fluxos é um SVG mantido em `docs/images/workflow.svg`.

## Diretrizes

- Mantenha trabalho de arquivos fora da thread principal.
- Preserve os originais e a política de não sobrescrita.
- Não aceite travessia de caminhos, links ou arquivos especiais sem uma revisão do modelo de segurança.
- Senhas não devem ir para logs, argumentos de processos, preferências ou manifests.
- Mudanças na publicação e no rollback precisam de testes que verifiquem a preservação dos arquivos existentes.
- Use textos em português na interface; atualize a documentação em português e a visão geral em inglês quando necessário.
- Não inclua arquivos pessoais, segredos, binários de build nem fixtures com direitos de terceiros sem licença.

## Pull requests

Descreva o problema, a mudança no comportamento e os testes realizados. Adicione capturas para mudanças visuais. Evite misturar refatorações amplas com correções pequenas. A contribuição é disponibilizada sob a [licença MIT](LICENSE).

## Estrutura

- `Sources/MacRar/`: SwiftUI, abertura pelo Finder e serviços de arquivo.
- `Sources/ArchiveBridge/`: subconjunto da ABI pública de libarchive e implementação C.
- `Tests/MacRarTests/`: testes do fluxo Swift e renderização opcional das capturas.
- `scripts/`: build, empacotamento e integração.
- `Casks/`: instalação pelo Homebrew.
- `docs/`: guias e imagens.
