# A stand-in for AnkiConnect, for testing Add to Anki without Anki: the actions the app
# uses (Anki.swift), with notes kept in memory. Prints each note added. Run it, then open a card.
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
decks={"Default":1}; models={"Basic":["Front","Back"]}; notes={}; nid=[1000]
def search(q):
    import shlex
    parts=shlex.split(q)  # handles the quoting
    out=[]
    for i,n in notes.items():
        ok=True
        for p in parts:
            k,_,v=p.partition(':'); v=v.replace('\\*','*').replace('\\_','_')
            if k=='deck' and n['deckName']!=v: ok=False
            if k=='note' and n['modelName']!=v: ok=False
            if k=='Chinese' and n['fields'].get('Chinese')!=v: ok=False
            if k=='nid' and str(i)!=v: ok=False
        if ok: out.append(i)
    return out
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        a=body['action']; p=body.get('params',{}); res=None; err=None
        if a=='deckNames': res=list(decks)
        elif a=='modelNames': res=list(models)
        elif a=='createModel': models[p['modelName']]=p['inOrderFields']; res={'name':p['modelName']}; print('MODEL', json.dumps(p, ensure_ascii=False)[:400])
        elif a=='createDeck': decks.setdefault(p['deck'],len(decks)+1); res=decks[p['deck']]
        elif a=='findNotes': res=search(p['query']); print('FIND', p['query'], '->', res)
        elif a=='addNote':
            n=p['note']
            if n['modelName'] not in models: err='model was not found: '+n['modelName']
            elif n['deckName'] not in decks: err='deck was not found: '+n['deckName']
            elif any(x['fields']['Chinese']==n['fields']['Chinese'] and x['deckName']==n['deckName'] for x in notes.values()): err='cannot create note because it is a duplicate'
            else: nid[0]+=1; notes[nid[0]]=n; res=nid[0]; print('ADD', json.dumps(n, ensure_ascii=False))
        elif a=='guiBrowse': res=[]; print('BROWSE', p['query'])
        else: err='unsupported action'
        out=json.dumps({'result':res,'error':err}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(out)
        sys.stdout.flush()
# A port as the first argument runs it beside the real Anki (dev builds: LONGYAN_ANKICONNECT_PORT).
HTTPServer(('127.0.0.1',int(sys.argv[1]) if len(sys.argv)>1 else 8765),H).serve_forever()
