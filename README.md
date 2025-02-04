# nasm_c2
Mini c2 in ASM x64. \
The code has been made as part of a course of Assembly, the code might neither be optimised nor perfect and very probably not secure enough.

## Contact 

Discord : \
- ``.naii.`` (don't forget the dots)\
- ``adam10_``

## Code
This repository contains a server-side code and a client-side code for a c2 in NASM x64. \
The present code is made to be used in localhost environnement as a proof of concept and must not be used for any illegal activities.

To compile and test the code, you can use the following commands :
```bash
nasm -f elf64 -o server.o server.asm && ld -o server server.o
nasm -f elf64 -o client.o client.asm && ld -o client client.o 
```
Or add this bash function to your .bash_aliases to compile with this single command ``asm server.asm && asm client.asm`` :
```bash
function asm(){
  if [ $# -ne 1 ]; then
    echo "Usage: asm <file.s>"
    return 1
  fi

  filename="${1%.*}"
  nasm -f elf64 -o "$filename.o" "$1" && ld -o "$filename" "$filename.o"
}
```
## What can it do right now ?
Currently, these actions can be done between client and server : 

  - Send message from **server** to **client**
  - Send message from **client** to **server**
  - Send "PING" from server and get a "PONG" response from client to verify that connection is established.
  - Send any bash commands to the client, the client will send the output to the server.

Commands can be used 2 ways:

 - Send the command to every client
 - Send the command to one specific client

To send a command to every client, just type the command and it'll send it to every client. \
For example : \
``PING`` will send a PING request to every client, and will receive the answer from each server.

To send a command to a specific client, you need to add ``<fd>:`` before your command \ 
For example : \
``4:bash ls`` will execute "ls" in the client with the file descriptor n°4 running directory


## Next upgrade
Next things that will be added if time is found:
 - 🗒️ File copying both way between client and server.
 - 🗒️ GUI to manage the clients. Either through WEB or APP also in assembly beacuse why not ?
 - 🗒️ Client screenshots mechanism

## Contribution
This code isn't really meant to exist outside of the course it very probably wont be maintained after it, but if you want to reuse it or upgrade it, feel free to do so.
If you want to make an upgrade on the code present on this repo, feel free to PM on discord.
