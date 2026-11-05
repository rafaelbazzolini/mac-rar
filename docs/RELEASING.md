# Publicar uma release

## Preparar

1. Atualize `CFBundleShortVersionString` e incremente `CFBundleVersion` em `scripts/Info.plist`.
2. Atualize `CHANGELOG.md`, notas de release e links de download no README quando necessário.
3. Execute testes e confira as alterações antes de criar o commit e a tag.

```sh
swift test --build-system native --disable-sandbox
python3 scripts/test-extraction.py
python3 scripts/test-compression.py
./scripts/package-release.sh
```

O empacotamento compila `arm64-apple-macosx13.0` e `x86_64-apple-macosx13.0`, verifica a arquitetura e a assinatura ad hoc e gera em `dist/release/` os ZIPs com `MacRar.app` e `SHA256SUMS.txt`. Os executáveis usam bibliotecas do sistema; não incluem instalações Homebrew. Teste o build Intel em um Mac Intel quando houver acesso; compilação cruzada não substitui validação no hardware.

A assinatura ad hoc não equivale a Developer ID ou notarização. Para distribuir uma release notarizada, use suas credenciais Developer ID, assine o bundle adequadamente, envie para o serviço da Apple, aplique o ticket e gere novamente os ZIPs e hashes. Não coloque credenciais no repositório.

## Publicar manualmente

Depois de revisar, criar o commit e enviar a tag:

```sh
git tag v2.1.0
git push origin main v2.1.0
gh release create v2.1.0 dist/release/*.zip dist/release/SHA256SUMS.txt \
  --verify-tag --title 'MacRar 2.1.0' --notes-file docs/releases/v2.1.0.md
```

Use a versão real da nova release; não substitua assets de uma versão publicada sem explicar a mudança e atualizar os hashes.

## GitHub Actions

O workflow **Build release** pode ser iniciado manualmente com uma tag existente. Ele confere se a tag coincide com a versão do app, empacota as duas arquiteturas e cria uma **release em rascunho**. Revise os assets e as notas antes de publicar. É necessário que a tag ainda não tenha uma release.

O workflow **CI** executa testes e compila ambas as arquiteturas em pushes e pull requests. Capturas gráficas e o teste de abertura real pelo Finder são destinados à sessão gráfica local.

## Atualizar o Homebrew

1. Publique os dois ZIPs da release antes de alterar o cask.
2. Edite `version` e os dois `sha256` em `Casks/mac-rar.rb` usando `SHA256SUMS.txt`.
3. Preserve os nomes dos assets ou ajuste a interpolação de arquitetura.
4. Valide o cask e os downloads:

```sh
brew tap rafaelbazzolini/mac-rar https://github.com/rafaelbazzolini/mac-rar
brew info --cask rafaelbazzolini/mac-rar/mac-rar
brew fetch --cask rafaelbazzolini/mac-rar/mac-rar
```

O cask usa a seleção de arquitetura documentada no [Homebrew Cask Cookbook](https://docs.brew.sh/Cask-Cookbook). A primeira release e o cask foram publicados juntos; futuras atualizações devem ser registradas no Git.
