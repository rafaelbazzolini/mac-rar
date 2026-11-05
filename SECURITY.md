# Segurança

## Versões atendidas

Correções são feitas na versão estável mais recente. Atualize antes de reportar um problema já corrigido. O projeto não oferece SLA de resposta.

## Reportar uma vulnerabilidade

Não publique arquivos maliciosos, dados privados ou instruções de exploração em uma issue pública. Use [Report a vulnerability](https://github.com/rafaelbazzolini/mac-rar/security/advisories/new) para enviar um relato privado ao mantenedor.

Inclua versão do MacRar e do macOS, formato do arquivo, impacto e passos de reprodução. Use fixtures sintéticas, sem dados pessoais. Nunca envie senhas ou documentos de terceiros sem autorização.

## Modelo e limites

O aplicativo usa a libarchive do sistema. Mantenha o macOS atualizado, pois correções do mecanismo de leitura dependem também da Apple. O app não é executado no App Sandbox; ele acessa arquivos com as permissões do usuário.

- Conteúdo é decodificado em uma pasta privada antes da publicação.
- Arquivos existentes não são sobrescritos.
- Links, arquivos especiais e caminhos inseguros são recusados na extração.
- Cancelamento e erros removem staging; a publicação tenta desfazer apenas as saídas criadas pela operação.
- ZIP com AES-256 cifra os dados, mas não oculta os nomes.
- O manifesto de partes não contém senha; ele verifica integridade, não autenticidade.
- Não há limite automático de tamanho expandido nem proteção completa contra esgotamento de disco.
- O teste de integridade não garante que os arquivos sejam seguros para executar.

As releases atuais têm assinatura ad hoc e não possuem notarização Apple. Os hashes SHA-256 permitem detectar alterações no download, mas não substituem uma assinatura Developer ID. Não desative globalmente as proteções do macOS para instalar o app.
