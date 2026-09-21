# Quarterly Dashboard - Integrado no VBM Kaizen App

Este é um sub-projeto independente dentro do **VBM Kaizen App**.

## 📁 Estrutura

```
vbm-kaizen-app/
├── (Kaizen App files)
│
└── Quartely/                          ⭐ SUB-PROJETO INDEPENDENTE
    ├── server.js                      Backend Express
    ├── index.html                     Frontend
    ├── chart.js                       D3 Visualization
    ├── style.css                      Styling
    ├── package.json                   Dependencies
    ├── .env.example                   Environment template
    ├── README.md                      Usage guide
    ├── DEPLOYMENT.md                  Deployment guide
    └── INTEGRATION.md                 Este arquivo
```

## 🚀 Executar Quartely Independentemente

### Opção A: Rodando como sub-projeto separado

```bash
# Terminal 1 - Kaizen App
cd vbm-kaizen-app
npm install
npm start

# Terminal 2 - Quartely (porta diferente)
cd vbm-kaizen-app/Quartely
npm install
DATABRICKS_APP_PORT=8001 npm start
```

**Resultado:**
- Kaizen App: `http://localhost:8000`
- Quartely: `http://localhost:8001`

### Opção B: Integrado na mesma porta

Para servir Quartely dentro da aplicação Kaizen, adicione esta rota no `server.js` principal:

```javascript
// No app.js (Kaizen) - após outras rotas
app.use('/quartely', express.static('Quartely'));
app.get('/quartely', (req, res) => {
  res.sendFile(path.join(__dirname, 'Quartely/index.html'));
});
```

**Resultado:** `http://localhost:8000/quartely`

---

## 🔐 Variáveis de Ambiente

Crie `.env` na pasta `Quartely/`:

```bash
cd Quartely
cp .env.example .env
# Edite com suas credenciais Databricks
```

**Exemplo:**
```env
DATABRICKS_HOST=seu-workspace.cloud.databricks.com
DATABRICKS_WAREHOUSE_ID=seu-warehouse-id
DATABRICKS_CLIENT_ID=seu-client-id
DATABRICKS_CLIENT_SECRET=seu-client-secret
DATABRICKS_APP_PORT=8001
```

---

## 📦 Dependências

Quartely possui suas próprias dependências em `package.json`:

```json
{
  "dependencies": {
    "express": "^5.2.1",
    "@databricks/sql": "^1.17.0",
    "d3": "^7.9.0",
    "compression": "^1.8.1"
  }
}
```

Instale com: `cd Quartely && npm install`

---

## 🎯 Recursos

✅ Visualização D3.js interativa  
✅ 5 Filtros dinâmicos  
✅ Tema escuro/claro  
✅ Multilíngue (PT-BR/EN)  
✅ Responsive design  
✅ Cache 5 minutos  
✅ Databricks OAuth  

---

## 🌐 Publicação

Quartely pode ser publicado **independentemente** do Kaizen App:

1. **Vercel** (Recomendado)
   - Root Directory: `Quartely`
   - Configure variáveis de ambiente
   - Deploy automático

2. **Railway/DigitalOcean**
   - Mesma abordagem
   - Não depende do Kaizen App

Veja `DEPLOYMENT.md` para detalhes completos.

---

## 🔗 URLs

| Componente | URL |
|-----------|-----|
| Kaizen App | `http://localhost:8000` |
| Quartely (separado) | `http://localhost:8001` |
| Quartely (integrado) | `http://localhost:8000/quartely` |
| API Chart Data | `http://localhost:8001/api/chart-data` |
| Health Check | `http://localhost:8001/api/health` |

---

## 📝 Notas Importantes

1. **Independência**: Quartely é um projeto completamente independente
2. **Dependências**: Possui seu próprio `package.json`
3. **Deploy**: Pode ser publicado sem publicar Kaizen
4. **Manutenção**: Updates no Quartely não afetam Kaizen
5. **Portas**: Use portas diferentes se rodar ambos localmente

---

## 🆘 Troubleshooting

**Erro: "Port already in use"**
```bash
# Usar porta diferente
DATABRICKS_APP_PORT=8002 npm start
```

**Erro: "DATABRICKS_HOST not found"**
```bash
# Verificar .env existe
cat Quartely/.env
```

**Erro: "Module not found"**
```bash
# Reinstalar dependências
cd Quartely
rm -rf node_modules package-lock.json
npm install
```

---

## 📚 Documentação

- **README.md** - Instruções de uso
- **DEPLOYMENT.md** - 6 Guias de publicação
- **INTEGRATION.md** - Este arquivo

---

**Última atualização:** 2025-09-21  
**Status:** ✅ Pronto para uso
