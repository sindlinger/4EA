// Minimal TCP socket helper for MT5 (length-prefixed JSON)
#ifndef MQL5_SOCKET_CLIENT_MQH
#define MQL5_SOCKET_CLIENT_MQH

int GpuSocketConnect(const string host, const ushort port, const uint timeout_ms)
{
   int sock = SocketCreate();
   if(sock == INVALID_HANDLE)
      return INVALID_HANDLE;

   if(!SocketConnect(sock, host, port, timeout_ms))
     {
      SocketClose(sock);
      return INVALID_HANDLE;
     }
   return sock;
}

bool GpuSocketSendJson(const int sock, const string json)
{
   uchar data[];
   int len = StringToCharArray(json, data, 0, -1, CP_UTF8) - 1;
   if(len <= 0)
      return false;

   uchar header[4];
   header[0] = (uchar)(len & 0xFF);
   header[1] = (uchar)((len >> 8) & 0xFF);
   header[2] = (uchar)((len >> 16) & 0xFF);
   header[3] = (uchar)((len >> 24) & 0xFF);

   if(SocketSend(sock, header, 4) != 4)
      return false;
   if(SocketSend(sock, data, len) != len)
      return false;
   return true;
}

bool GpuSocketRecvJson(const int sock, string &out_json, const uint timeout_ms)
{
   uchar header[4];
   int got = SocketRead(sock, header, 4, timeout_ms);
   if(got != 4)
      return false;

   int len = (int)header[0] | ((int)header[1] << 8) | ((int)header[2] << 16) | ((int)header[3] << 24);
   if(len <= 0)
     {
      out_json = "";
      return true;
     }

   uchar data[];
   ArrayResize(data, len);
   int read_total = 0;
   while(read_total < len)
     {
      uchar tmp[];
      int remain = len - read_total;
      ArrayResize(tmp, remain);
      int chunk = SocketRead(sock, tmp, remain, timeout_ms);
      if(chunk <= 0)
         return false;
      ArrayCopy(data, tmp, read_total, 0, chunk);
      read_total += chunk;
     }

   out_json = CharArrayToString(data, 0, len, CP_UTF8);
   return true;
}

void GpuSocketClose(const int sock)
{
   if(sock != INVALID_HANDLE)
      SocketClose(sock);
}

#endif // MQL5_SOCKET_CLIENT_MQH
