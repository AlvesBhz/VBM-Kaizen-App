/**
 * VBM Kaizen — entrega otimizada das fotos de Antes/Depois.
 *
 * POR QUE EXISTE
 *   As fotos são gravadas como vieram do celular: vários MB e ~4000 px de
 *   largura. A tela mostra cada uma numa caixa de no máximo ~800 px (o
 *   modal da Biblioteca/Aprovação) e o PDF A4 em meia página. Mandar o
 *   original é baixar dezenas de vezes mais bytes do que a tela usa — é
 *   isso que deixa o modal girando, não a quantidade de arquivos nas
 *   pastas do Blob (o Blob acha um arquivo pelo nome completo, custe a
 *   pasta ter 12 ou 12 mil).
 *
 * O QUE FAZ
 *   - Redimensiona para uma das LARGURAS_PERMITIDAS e converte para WebP,
 *     respeitando a orientação gravada pela câmera (EXIF) — sem isso,
 *     foto tirada com o celular em pé sairia deitada, porque o
 *     redimensionamento descarta os metadados.
 *   - Guarda o resultado em memória (LRU limitado por BYTES), para o
 *     segundo usuário que abre o mesmo Kaizen não pagar o processamento.
 *   - Junta pedidos simultâneos da mesma foto num processamento só.
 *   - Lembra por alguns minutos que uma foto NÃO existe, para não ir ao
 *     Blob a cada tentativa de exibir um Kaizen sem a foto.
 *
 * SEM sharp
 *   `sharp` é dependência OPCIONAL (package.json). Se não instalar no
 *   ambiente, disponivel() devolve false e a rota serve o original, como
 *   antes — nada quebra, só não fica mais leve.
 *
 * Nada aqui grava no Blob: não há pasta nova de miniaturas. O cache vive
 * na memória do processo e some num restart (a próxima abertura refaz).
 */

let sharp = null;
try {
  sharp = require("sharp");
  // Sem o cache interno do libvips: o nosso (abaixo) já guarda o
  // resultado, e o dele guardaria de novo a imagem ORIGINAL decodificada.
  sharp.cache(false);
} catch (err) {
  console.warn(`[fotos] sharp indisponível (${err.message}) — as fotos seguem no tamanho original.`);
}

/** Larguras aceitas no ?w=. Lista fechada de propósito: com largura livre,
 *  qualquer um encheria o cache (e a CPU) pedindo w=1, w=2, w=3... */
const LARGURAS_PERMITIDAS = [1280, 1600];
const QUALIDADE_WEBP = 80;

const LIMITE_CACHE_BYTES = 64 * 1024 * 1024; // ~250-400 fotos de tela
const AUSENTE_TTL_MS = 5 * 60 * 1000;

const cache = new Map(); // chave -> { buffer, contentType } (ordem = uso)
let bytesEmCache = 0;
const emAndamento = new Map(); // chave -> Promise
const ausentes = new Map(); // caminho -> expira em (ms)

function disponivel() {
  return Boolean(sharp);
}

function larguraValida(valor) {
  const n = Number(valor);
  return LARGURAS_PERMITIDAS.includes(n) ? n : null;
}

function lerDoCache(chave) {
  const item = cache.get(chave);
  if (!item) return null;
  // Reinsere para marcar como usado agora (Map mantém a ordem de inserção).
  cache.delete(chave);
  cache.set(chave, item);
  return item;
}

function guardarNoCache(chave, item) {
  if (item.buffer.length > LIMITE_CACHE_BYTES / 8) return; // não deixa uma só expulsar tudo
  const anterior = cache.get(chave);
  if (anterior) {
    bytesEmCache -= anterior.buffer.length;
    cache.delete(chave);
  }
  cache.set(chave, item);
  bytesEmCache += item.buffer.length;
  for (const [k, v] of cache) {
    if (bytesEmCache <= LIMITE_CACHE_BYTES) break;
    cache.delete(k);
    bytesEmCache -= v.buffer.length;
  }
}

/** Esquece tudo o que se sabe de `caminho`: versões redimensionadas e a
 *  marca de "não existe". Chamado ao gravar ou apagar a foto — o nome do
 *  arquivo é o ID do Kaizen e não muda quando a foto é trocada. */
function invalidar(caminho) {
  ausentes.delete(caminho);
  const prefixo = caminho + "|";
  for (const [k, v] of cache) {
    if (!k.startsWith(prefixo)) continue;
    cache.delete(k);
    bytesEmCache -= v.buffer.length;
  }
}

function marcarAusente(caminho) {
  ausentes.set(caminho, Date.now() + AUSENTE_TTL_MS);
}

function estaAusente(caminho) {
  const expira = ausentes.get(caminho);
  if (!expira) return false;
  if (expira > Date.now()) return true;
  ausentes.delete(caminho);
  return false;
}

/** Foto de `caminho` redimensionada para `largura`, em WebP.
 *
 *  `lerOriginal` é quem busca os bytes (Blob ou Volume) — este módulo não
 *  sabe de armazenamento. `versao` entra na chave: é o ?v= que a tela já
 *  manda e que muda quando a foto é trocada.
 *
 *  Se o sharp não conseguir ler o arquivo (formato que ele não decodifica,
 *  arquivo corrompido), devolve o ORIGINAL em vez de falhar: a foto
 *  aparece, só não fica mais leve. */
async function obterRedimensionada(caminho, versao, largura, lerOriginal) {
  const chave = `${caminho}|${versao || ""}|${largura}`;
  const emCache = lerDoCache(chave);
  if (emCache) return emCache;
  if (emAndamento.has(chave)) return emAndamento.get(chave);

  const tarefa = (async () => {
    const { buffer, contentType } = await lerOriginal();
    let item;
    try {
      const saida = await sharp(buffer, { failOn: "none" })
        .rotate() // aplica a orientação do EXIF antes que ela se perca
        // O LADO MAIOR fica em `largura`: foto em pé também cabe — limitar
        // só a largura deixaria uma de 1280 de largura com 1707 de altura.
        .resize({ width: largura, height: largura, fit: "inside", withoutEnlargement: true })
        .webp({ quality: QUALIDADE_WEBP })
        .toBuffer();
      item = { buffer: saida, contentType: "image/webp" };
    } catch (err) {
      console.warn(`[fotos] não foi possível redimensionar ${caminho}: ${err.message} — servindo o original.`);
      item = { buffer, contentType };
    }
    guardarNoCache(chave, item);
    return item;
  })();

  emAndamento.set(chave, tarefa);
  try {
    return await tarefa;
  } finally {
    emAndamento.delete(chave);
  }
}

module.exports = {
  LARGURAS_PERMITIDAS,
  disponivel,
  larguraValida,
  obterRedimensionada,
  invalidar,
  marcarAusente,
  estaAusente,
};
