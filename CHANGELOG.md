# Changelog

As mudanças relevantes são registradas aqui. Versões públicas usam tags `vMAJOR.MINOR.PATCH`.

## [2.1.0] — 2026-11-05

Primeira publicação pública do MacRar.

### Recursos

- Interface nativa em SwiftUI com extração em lote de RAR, ZIP, 7z e TAR.
- Modos em nova pasta e Extrair aqui, sem sobrescrever arquivos existentes.
- Extração automática pelo Finder e solicitação de senha quando necessária.
- Criação de ZIP, 7z, TAR, TAR.GZ, TAR.BZ2 e TAR.XZ.
- ZIP com AES-256, níveis de compressão e verificação após criar.
- Prévia do conteúdo com busca e teste de integridade.
- Partes binárias numeradas com manifesto SHA-256.
- Cancelamento cooperativo, arquivos ocultos opcionais e abertura do destino no Finder.
- Ícone próprio, documentação e builds separados para Apple Silicon e Intel.
- Instalação por tap Homebrew próprio.

### Limitações da distribuição

- Assinatura ad hoc, sem notarização da Apple.
- Build Intel compilado cruzadamente, sem validação em hardware Intel nesta publicação.
- Sem criação RAR, reparação, arquivos autoextraíveis ou edição de arquivos compactados existentes.

[2.1.0]: https://github.com/rafaelbazzolini/mac-rar/releases/tag/v2.1.0
