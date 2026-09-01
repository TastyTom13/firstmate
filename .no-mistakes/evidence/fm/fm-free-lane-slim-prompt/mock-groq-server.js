const http = require('http');
const fs = require('fs');
const out = process.argv[2];
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', c => body += c);
  req.on('end', () => {
    let est = 0, parsed = null;
    try {
      parsed = JSON.parse(body);
      const msgs = parsed.messages || [];
      const text = msgs.map(m => typeof m.content === 'string' ? m.content : JSON.stringify(m.content)).join('');
      const tools = JSON.stringify(parsed.tools || []);
      est = Math.ceil((text.length + (parsed.tools ? tools.length : 0)) / 4);
      fs.writeFileSync(out, JSON.stringify({
        estimated_prompt_tokens: est,
        message_chars: text.length,
        tool_def_chars: parsed.tools ? tools.length : 0,
        n_messages: msgs.length,
        n_tools: (parsed.tools || []).length,
        system_preview: (msgs[0] && String(msgs[0].content).slice(0, 200)) || ''
      }, null, 2));
    } catch (e) { fs.writeFileSync(out, 'parse-error: ' + e.message); }
    const id='chatcmpl-mock';
    if (parsed && parsed.stream) {
      res.writeHead(200, {'Content-Type': 'text/event-stream'});
      const chunk = (d) => res.write('data: ' + JSON.stringify(d) + '\n\n');
      chunk({id, object:'chat.completion.chunk', created:1, model:'mock', choices:[{index:0, delta:{role:'assistant', content:'MOCK-REPLY'}, finish_reason:null}]});
      chunk({id, object:'chat.completion.chunk', created:1, model:'mock', choices:[{index:0, delta:{}, finish_reason:'stop'}], usage:{prompt_tokens:est, completion_tokens:1, total_tokens:est+1}});
      res.write('data: [DONE]\n\n');
      res.end();
    } else {
      res.writeHead(200, {'Content-Type': 'application/json'});
      res.end(JSON.stringify({
        id, object: 'chat.completion', created: 1, model: 'mock',
        choices: [{index: 0, message: {role: 'assistant', content: 'MOCK-REPLY'}, finish_reason: 'stop'}],
        usage: {prompt_tokens: est, completion_tokens: 1, total_tokens: est + 1}
      }));
    }
  });
});
server.listen(8731, () => console.log('mock listening'));
