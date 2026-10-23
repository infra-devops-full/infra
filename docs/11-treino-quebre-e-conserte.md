# Treino: quebre e conserte

Este é o jeito mais rápido de aprender a operar Kubernetes: quebrar algo de
propósito, observar o sintoma e achar a causa **só com as ferramentas de
diagnóstico**. Os sintomas descritos aqui foram observados neste cluster
(k3d com 1 server e 1 agent).

## Como funciona o laboratório

```bash
make lab-up       # instala (ou RESTAURA) o app demo no namespace treino
make lab-status   # pods, endpoints, ingress, eventos recentes e HTTP do demo
make lab-down     # remove tudo
```

- O **demo** usa o mesmo chart genérico dos projetos (`charts/app`) e a imagem
  pública do `products` (NestJS, porta 3000). Os valores estão em
  [`labs/demo-values.yaml`](labs/demo-values.yaml).
- Ele é instalado por Helm, **fora do ArgoCD**. Se você quebrar um app de
  projeto (crivo, wlstore…) com `kubectl`, o ArgoCD desfaz em segundos. O
  exercício 11 mostra isso.
- Para testar o app:
  ```bash
  curl --resolve demo.treino.local:80:127.0.0.1 http://demo.treino.local/
  ```
- **Antes de cada exercício, rode `make lab-up`** para partir do estado bom.
  Ele restaura tudo, inclusive o que você mudou com `kubectl` (usa
  `--force-conflicts`; veja o quadro abaixo).

### O kit de diagnóstico (use sempre nesta ordem)

| Pergunta | Comando |
| -------- | ------- |
| Os pods estão de pé? | `kubectl get pods -n treino` |
| O que o Kubernetes tentou fazer? | `kubectl get events -n treino --sort-by=.lastTimestamp` |
| Por que este pod está assim? | `kubectl describe pod -n treino <pod>` (leia o fim: **Events**) |
| O que a aplicação disse? | `kubectl logs -n treino <pod>` (e `--previous` se ele reiniciou) |
| O Service acha os pods? | `kubectl get endpoints -n treino demo` |
| Como está configurado? | `kubectl get deploy,svc,ingress -n treino demo -o yaml` |

> **Regra de ouro:** o sintoma (HTTP 503, 502, 404) diz **onde** olhar; os
> eventos e o `describe` dizem **por quê**.

> **Quadro: quem é o dono de cada campo (server-side apply).** Quando você
> altera um campo com `kubectl patch/set`, o Kubernetes registra o
> `kubectl-patch` como "dono" desse campo. Um `helm upgrade` normal então
> **recusa** sobrescrever (`Apply failed with N conflicts`). O `make lab-up`
> usa `--force-conflicts` para retomar a posse. Em produção, esse conflito é um
> aviso valioso: alguém mudou na mão algo que deveria estar no Git.

---

## Exercício 1: imagem que não existe

**Quebre:**
```bash
kubectl -n treino set image deploy/demo demo=ghcr.io/geraldobl58/microservice-with-nestjs-rabbitmq/products:nao-existe
```

**Sintoma observado:** um pod novo em `ImagePullBackOff` (eventos `Failed`)…
mas o site **continua respondendo 200**.

<details><summary>Dica</summary>

Compare os dois pods (`kubectl get pods -n treino`). Por que o antigo ainda está
lá? Leia o fim de `kubectl describe pod` do novo.
</details>

<details><summary>Solução e conceito</summary>

- **Causa:** a tag `nao-existe` não está no registry. Nos eventos:
  `Failed to pull image "…:nao-existe": rpc error: code = NotFound … failed to resolve reference`.
- **Por que o site não caiu:** o rollout (`RollingUpdate`) só derruba o pod
  antigo depois que o novo fica pronto. O deploy **travou**, mas o tráfego
  segue no pod velho. Veja com `kubectl rollout status deploy/demo -n treino`,
  que fica esperando.
- **Conserto:** voltar a tag certa (`make lab-up`) ou desfazer o rollout:
  `kubectl rollout undo deploy/demo -n treino`.
- **Na vida real:** é o que acontece quando o CI publica a tag no Git antes de
  a imagem existir, ou com imagem só `amd64` num node `arm64`
  (`no match for platform in manifest`).
</details>

---

## Exercício 2: Service apontando para a porta errada

**Quebre:**
```bash
kubectl -n treino patch svc demo --type json \
  -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":9999}]'
```

**Sintoma observado:** depois de ~10 s, **HTTP 502**. O pod segue `1/1 Running`
e não há eventos de erro.

<details><summary>Dica</summary>

O pod está saudável, então o problema está **entre** o Ingress e o pod. Compare
`kubectl get endpoints -n treino demo` com a porta em que o container escuta
(`kubectl get pod … -o jsonpath='{..containerPort}'`).
</details>

<details><summary>Solução e conceito</summary>

- **502 Bad Gateway** = o Ingress achou um destino, mas a conexão falhou
  (porta 9999 fechada no pod).
- Os ~10 s de atraso são o tempo de o Ingress receber os endpoints novos.
- **Conserto:** `make lab-up`. No chart, o `targetPort` é a porta **nomeada**
  `http`, igual ao `service.port`. Por isso, no `values.yaml`, o `service.port`
  precisa bater com a porta em que o app escuta.
</details>

---

## Exercício 3: Service que não encontra os pods

**Quebre:**
```bash
kubectl -n treino patch svc demo -p '{"spec":{"selector":{"app.kubernetes.io/name":"dem0"}}}'
```

**Sintoma observado:** **HTTP 503**, com o pod `1/1 Running`.

<details><summary>Dica</summary>

`kubectl get endpoints -n treino demo`. O que aparece na coluna ENDPOINTS? Agora
compare o `selector` do Service com os labels do pod (`kubectl get pod --show-labels -n treino`).
</details>

<details><summary>Solução e conceito</summary>

- O Service escolhe os pods **por label**. Com `dem0` (zero), nenhum pod bate,
  os endpoints ficam **vazios**, e o Ingress responde **503 Service
  Unavailable**.
- **502 × 503:** 502 = existe destino, mas a conexão falha. 503 = não existe
  destino pronto.
- **Conserto:** `make lab-up`.
</details>

---

## Exercício 4: Secret que sumiu

**Quebre:**
```bash
kubectl -n treino delete secret demo-config
kubectl -n treino delete pod -l app.kubernetes.io/name=demo
```

**Sintoma observado:** pod em **`CreateContainerConfigError`** e **HTTP 503**.

<details><summary>Dica</summary>

`describe` do pod, na seção Events. Depois procure no Deployment de onde vêm as
variáveis (`envFrom`).
</details>

<details><summary>Solução e conceito</summary>

- O container nem chega a ser criado: o `envFrom` aponta para o Secret
  `demo-config`, que não existe (`Error: secret "demo-config" not found`).
- Diferente do exercício 1, aqui o pod antigo foi apagado, então **não sobrou
  ninguém servindo**: 503.
- **Conserto:** recriar o Secret (`make lab-up`). Nos projetos, é o
  `make project-apply PROJECT=<p>` ou `make secrets PROJECT=<p> ENV=<e>`.
- Se o Secret for opcional, o chart aceita `optional: true` no `envFrom`.
</details>

---

## Exercício 5: memória insuficiente

**Quebre:**
```bash
kubectl -n treino set resources deploy/demo -c demo --limits=memory=24Mi --requests=memory=24Mi
```

**Sintoma observado:** pod novo em **`CrashLoopBackOff`**, com restarts
subindo. O site segue **200** no pod antigo.

<details><summary>Dica</summary>

Os logs do container que morreu não explicam. Olhe o **último estado** dele:
```bash
kubectl -n treino get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason} {.status.containerStatuses[0].lastState.terminated.exitCode}'
```
</details>

<details><summary>Solução e conceito</summary>

- **`OOMKilled`, exit code 137:** o processo Node passou de 24Mi e o kernel o
  matou. O Kubernetes reinicia, ele morre de novo, e vira `CrashLoopBackOff`
  (o intervalo entre tentativas cresce).
- **Exit 137** = morto por sinal 9 (SIGKILL). É a assinatura de OOM.
- **Conserto:** `make lab-up` (limit 192Mi). Para dimensionar, olhe a memória
  real no Grafana (*Platform / Apps* → Memória) e dê folga ao `limits.memory`.
  Nos apps Java, o heap segue o limite (`MaxRAMPercentage=75`).
</details>

---

## Exercício 6: pod que não cabe no cluster

**Quebre:**
```bash
kubectl -n treino set resources deploy/demo -c demo --requests=cpu=50 --limits=cpu=50
```

**Sintoma observado:** pod novo **`Pending`** para sempre, com o evento
`FailedScheduling: 0/2 nodes are available: 2 Insufficient cpu`. O site segue
200 no pod antigo.

<details><summary>Dica</summary>

`Pending` = o scheduler não achou lugar. Os eventos dizem o motivo. Quanto de
CPU você pediu? Quanto os nodes têm (`kubectl describe node | grep -A5 Allocatable`)?
</details>

<details><summary>Solução e conceito</summary>

- `requests` é o que o pod **reserva**. O scheduler só coloca o pod num node
  com essa sobra. 50 CPUs não existem em nenhum node.
- **Pegadinha:** se você tentar só `--requests=cpu=50`, a API **recusa**,
  porque o request não pode passar do `limit` (200m).
- **Conserto:** `make lab-up`. Na vida real, `Pending` também aparece por
  falta de memória, `nodeSelector` impossível ou PVC sem volume.
</details>

---

## Exercício 7: readiness probe errada

**Quebre:**
```bash
kubectl -n treino patch deploy demo --type json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/nao-existe"}]'
```

**Sintoma observado:** pod novo `0/1 Running` (nunca fica pronto), eventos
`Unhealthy` (`Readiness probe failed: HTTP probe failed with statuscode: 404`).
O antigo continua atendendo.

<details><summary>Dica</summary>

`Running` mas `0/1`: o processo está vivo, mas o Kubernetes não o considera
pronto. Quem decide isso?
</details>

<details><summary>Solução e conceito</summary>

- **Readiness** decide se o pod **recebe tráfego**. Falhando, ele sai dos
  endpoints, mas **não reinicia**.
- **Conserto:** `make lab-up`. Para escolher o path certo: Nest/Node usam `/`
  ou `/health`; Spring sem actuator usa `/v3/api-docs` (é o caso dos serviços
  do wlstore); microfrontend usa o `basePath`.
</details>

---

## Exercício 8: liveness probe errada

**Quebre:**
```bash
kubectl -n treino patch deploy demo --type json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/nao-existe"},
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds","value":5}]'
```

**Sintoma observado:** o pod fica `1/1` e responde 200, mas o **RESTARTS**
sobe a cada ~1 min, com eventos `Unhealthy` (Liveness).

<details><summary>Dica</summary>

Compare com o exercício 7: agora o pod **reinicia**. `kubectl describe pod` →
`Last State: Terminated`, `Reason`?
</details>

<details><summary>Solução e conceito</summary>

- **Liveness** decide se o container está **travado**. Falhando
  `failureThreshold` vezes, o kubelet **mata e reinicia** o container.
- Liveness errada é traiçoeira: o app parece bem, mas reinicia sem parar e
  derruba conexões. Em Java, um `initialDelaySeconds` curto mata o app antes
  de o Flyway terminar (por isso os serviços do wlstore usam 60 s).
- **Conserto:** `make lab-up`.
</details>

---

## Exercício 9: Ingress com host errado

**Quebre:**
```bash
kubectl -n treino patch ingress demo --type json \
  -p '[{"op":"replace","path":"/spec/rules/0/host","value":"demo-errado.treino.local"}]'
```

**Sintoma observado:** **HTTP 404** (página do nginx), com pod e Service
perfeitos.

<details><summary>Dica</summary>

`kubectl get ingress -n treino`. Qual host está publicado? E qual você está
chamando?
</details>

<details><summary>Solução e conceito</summary>

- O NGINX Ingress roteia pelo **Host** do request. Nenhuma regra para
  `demo.treino.local` = 404 do próprio nginx (o app nem é chamado).
- Nos projetos, o host vem do `ingress.host` ou da regra
  `<env>.<app>.<projeto>.local` (sem prefixo em prod), e o `/etc/hosts` precisa
  ter a entrada (`make hosts`).
- **Conserto:** `make lab-up`.
</details>

---

## Exercício 10: DNS dentro do cluster

**Investigue** (não quebra nada): suba um pod temporário com curl e teste os
nomes.
```bash
kubectl run dnsprobe -n treino --rm -it --restart=Never --image=curlimages/curl -- sh
# dentro do pod:
curl -s -o /dev/null -w "%{http_code}\n" http://demo:3000/
curl -s -o /dev/null -w "%{http_code}\n" http://demo.treino.svc.cluster.local:3000/
curl -s -o /dev/null -w "%{http_code} exit=%{exitcode}\n" --max-time 5 http://dem0:3000/
```

**Observado:** `demo:3000` → 200, o nome completo → 200, `dem0:3000` → `000
exit=6` (não resolve).

<details><summary>Conceito</summary>

- Todo Service ganha um nome DNS: `<service>.<namespace>.svc.cluster.local`.
  **No mesmo namespace**, basta `<service>`.
- É por isso que o `crivo-fe` chama `http://crivo-be:8080` e o shell do wlstore
  pode achar mfes pelo nome: funciona igual em develop e em prod, porque cada
  ambiente é um namespace.
- `exit=6` do curl = *couldn't resolve host*. Se você vir isso num app, o nome
  do Service (ou o namespace) está errado.
</details>

---

## Exercício 11: por que minha mudança sumiu? (GitOps)

**Faça** num app de **projeto** (gerenciado pelo ArgoCD):
```bash
kubectl -n crivo-develop scale deploy/crivo-fe --replicas=0
kubectl -n crivo-develop get deploy crivo-fe -w     # Ctrl+C para sair
```

**Observado:** em ~2 s o ArgoCD volta para `replicas: 1`.

<details><summary>Conceito</summary>

- O ArgoCD está com **selfHeal**: ele compara o cluster com o Git o tempo todo
  e desfaz qualquer diferença. No histórico da Application (*History and
  Rollback*) e nos eventos aparece o sync.
- **Lição:** em GitOps, `kubectl edit/scale/set` em app de projeto só vale para
  diagnóstico rápido. A mudança de verdade é **commit** em
  `projects/<p>/apps/<app>/values*.yaml`.
- É exatamente por isso que o laboratório (`treino`) fica fora do ArgoCD.
</details>

---

## Exercício 12: encontre o erro pela observabilidade

**Gere tráfego com erro** num app de projeto:
```bash
for i in $(seq 1 50); do
  curl -s -o /dev/null --resolve develop.crivo-be.crivo.local:80:127.0.0.1 http://develop.crivo-be.crivo.local/nao-existe
done
```

**Encontre no Grafana** (http://grafana.devops.local → *Platform / Apps*,
projeto `crivo`, ambiente `develop`):

1. Em **Respostas por status HTTP**, o pico de `4xx`.
2. Em **Erros 4xx/5xx por app**: qual app e qual código?
3. Em **Explore → Loki**, os logs do backend nessa janela:
   ```logql
   {namespace="crivo-develop", app="crivo-be"} |= "nao-existe"
   ```
4. Em **Explore → Prometheus**, a taxa de 404 por app:
   ```promql
   sum by (ingress) (rate(nginx_ingress_controller_requests{exported_namespace="crivo-develop", status="404"}[5m]))
   ```

<details><summary>Conceito</summary>

As **métricas** dizem *que* algo está errado e *quanto*. Os **logs** dizem *o
quê*. Comece pelo dashboard, filtre o período do pico e só então vá aos logs.
</details>

---

## Exercício 13: rollback pelo Git

Um deploy ruim chegou em **develop** (simule com o `nest-rabbitmq`):

1. No repo de infra, troque a tag em
   `projects/nest-rabbitmq/apps/products/values-develop.yaml` por uma que não
   existe (`sha-0000000`), depois commit e push.
2. Veja no ArgoCD `nest-rabbitmq-products-develop` ficar **Degraded**, e no
   cluster o pod em `ImagePullBackOff`. O antigo continua servindo (exercício 1).
3. Volte com o próprio Git:
   ```bash
   git revert HEAD && git push
   ```
4. Clique *Refresh* no ArgoCD (ou rode `make refresh`) e veja voltar a
   **Healthy**.

<details><summary>Conceito</summary>

Em GitOps, **rollback = reverter o commit**. O histórico do Git vira o
histórico de deploys: quem mudou, quando e por quê. O botão *Rollback* do
ArgoCD funciona, mas fica em desacordo com o Git; com selfHeal ligado, o Git
sempre ganha.
</details>

---

## Exercício 14: o gate de qualidade bloqueando um PR

1. No repo do **nest**, numa branch `feature/quebra-teste` a partir da
   `develop`, mude o texto esperado em `products/src/app.controller.spec.ts`.
2. Abra um PR para a `develop`. O job **test** falha e o check **ci** fica
   vermelho.
3. Abra o log do job: qual teste, qual valor esperado e qual recebido?
4. Feche o PR (ou corrija e veja ficar verde).

<details><summary>Conceito</summary>

O check `ci` é o que a proteção da `main` exige. Com ele, código que quebra
teste **não chega em produção**, e a falha aparece no PR, não no cluster.
</details>

---

## Desafio final: o incidente misterioso

Peça para alguém (ou faça você, sem olhar) aplicar **duas** quebras ao mesmo
tempo, por exemplo os exercícios 3 e 5. Depois diagnostique **só** com
`make lab-status`, `describe`, `events` e `logs`, escrevendo:

1. o sintoma visto pelo usuário;
2. a evidência de cada causa (o comando e o trecho da saída);
3. a correção e como evitar que se repita.

Esse formato (sintoma → evidência → causa → correção → prevenção) é o de um
**post-mortem**, e é o que se espera de quem opera produção.

## Resumo dos sintomas

| Sintoma | Causa provável | Onde confirmar |
| ------- | -------------- | -------------- |
| `ImagePullBackOff` / `ErrImagePull` | tag inexistente, imagem privada sem credencial, arquitetura errada | `describe pod` (Events) |
| `CreateContainerConfigError` | Secret ou ConfigMap do `envFrom` não existe | `describe pod` |
| `CrashLoopBackOff` | o app morre ao subir: erro de config, ou `OOMKilled` (exit 137) | `logs --previous` e `lastState.terminated` |
| `Pending` | sem recurso (CPU/memória), `nodeSelector` impossível | eventos `FailedScheduling` |
| `Running` `0/1` | readiness falhando | eventos `Unhealthy` |
| `RESTARTS` subindo, mas `1/1` | liveness falhando, ou OOM intermitente | `describe pod` (Last State) |
| HTTP 404 do nginx | nenhum Ingress com esse host/path | `kubectl get ingress -A` |
| HTTP 502 | o destino existe, mas a conexão falha (porta errada, app caído) | `get endpoints` × porta do container |
| HTTP 503 | nenhum pod pronto atrás do Service | `get endpoints` vazio |
| "minha mudança sumiu" | selfHeal do ArgoCD | o Git é a fonte da verdade |
