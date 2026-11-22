# AWS - Operación administrativa y CloudShell

Para crear una aplicación nueva, usa [setup.md](../../setup.md).
Esta guía no es otro instalador: no copies políticas antiguas, no vuelvas a
ejecutar setup para reparar una aplicación y no elimines recursos compartidos.

## Identidad y alcance

En CloudShell o Bash con una sesión administrativa autorizada:

```bash
export APP_NAME="my-app"
export STAGE="dev"                 # dev o prod, no main
export AWS_REGION="us-east-2"
aws sts get-caller-identity
```

Confirma la cuenta, región, repositorio y aplicación antes de cualquier cambio.
CloudShell usa la sesión actual; en local selecciona un perfil existente si
corresponde. Las credenciales administrativas no se copian a GitHub ni al frontend.

El rol de despliegue es `{app}-{GitHub-repository-ID}-github-deploy`;
su política inline es `{app}-deploy`. IAM es global dentro de la cuenta.
El proveedor OIDC de GitHub puede ser compartido por varias aplicaciones.

## Diagnosticar primero

Sigue [aws-cli-resource-explorer.md](aws-cli-resource-explorer.md) para inspección
sin cambios: stacks, recursos anidados, eventos fallidos, exports y estado Lambda.
Consulta [ci-cd-issues.md](ci-cd-issues.md) para errores del pipeline y Vercel.
No imprimas tokens, contraseñas, valores de Secrets Manager ni datos de clientes.

Si faltan permisos, sigue [iam-issues.md](iam-issues.md):

1. Identifica el rol existente y la acción/ARN exactos del error.
2. Con aprobación explícita, genera la política actual desde
   [aws/iam.json](../../aws/iam.json) usando las funciones de
   [common.ps1](../../setup-scripts/common.ps1) y los datos reales de la aplicación.
3. Actualiza solo el rol aprobado; verifica trust para los entornos GitHub
   `prod`/`dev`, sin comodines de repositorios, ramas o PR.
4. Ejecuta el workflow de esa aplicación y verifica despliegue y pruebas reales.

Actualizar archivos locales no actualiza automáticamente un rol existente.
No sustituyas permisos limitados por AdministratorAccess para ocultar el error.

## Despliegue y límites actuales

Normalmente despliega GitHub Actions: pruebas completas, selección de componentes,
fase 1 que conserva compute existente, imagen Lambda, fase 2, publicación Vercel
y pruebas posteriores. Usa [README.md](../../README.md) y la
[orientación de infraestructura](../repos/aws-infra.md) como referencia.
Un despliegue manual requiere aprobación y no reemplaza la aceptación del pipeline.

El shell crea un placeholder Secrets Manager, pero no carga sus valores al
runtime. Los contratos de secretos, integraciones SES/Stripe, dominios personalizados
y usuarios administradores de producto requieren diseño e implementación explícitos.
La autorización admin actual usa el grupo Cognito `admin`; no asumas que
`ADMIN_SUB` concede por sí solo ese rol. El usuario temporal de pruebas no es admin.

## Eliminación permanente

Primero revisa el inventario sin eliminar:

```bash
bash ./scripts/destroy.sh -Plan
bash ./scripts/purge.sh -AppName my-app -Plan
```

Consulta [setup.md](../../setup.md#scripts) antes de autorizar la operación real.
Destroy elimina recursos de los stacks de la app y sus datos retenidos, pausa
Vercel Production y conserva repo/bootstrap. Purge elimina también repositorio,
proyectos Vercel coincidentes y recursos/huérfanos exactos de la app.

Ambos pueden borrar permanentemente usuarios, datos, archivos y secretos.
No restauran backups ni recuperan datos al volver a desplegar. Conserva los
journals `.setup/teardown.json` o `.setup/purge-*.json` tras una interrupción:
los reintentos validan identidades y bloquean recursos reemplazados.

No uses `delete-stack` como sustituto del inventario/limpieza verificada.
No elimines el proveedor OIDC compartido, recursos de otra app, ni journals para
evitar sus protecciones. Una recuperación parcial puede dejar workflows deshabilitados.
