import std.stdio;
import std.array;
import std.conv;
import std.file;
import std.algorithm;

import idjit;

BasicBlock compileNaiveBF(string input)
{
    BasicBlock block;
    uint labelIndex = 0;
    uint[] labelStack;

    with (block) with (Register) with (OperandType)
    {
        // Load in array at EBX, as the D ABI guarantees it won't be 
        // trampled by function calls
        mov(EBX, _(EBP, 8));

        foreach (c; input)
        {
            // *ptr++
            if (c == '+')
            {
                add(_(Byte, EBX), 1);
            }
            // *ptr--
            else if (c == '-')
            {
                sub(_(Byte, EBX), 1);
            }
            // ptr++
            else if (c == '>')
            {
                inc(EBX);
            }
            // ptr--
            else if (c == '<')
            {
                dec(EBX);
            }
            // putchar(*ptr)
            else if (c == '.')
            {
                mov(EAX, _(Byte, EBX));
                call(&putchar);
            }
            // *ptr = getchar()
            else if (c == ',')
            {
                call(&getchar);
                mov(_(Byte, EBX), EAX);
            }
            // while (*ptr) {
            else if (c == '[')
            {
                // Generate label
                auto labelString = labelIndex.to!string();

                mov(EAX, _(Byte, EBX));
                cmp(EAX, 0);
                je("r" ~ labelString);
                label("l" ~ labelString);

                // Push back the current index to the label stack
                labelStack ~= labelIndex;
                ++labelIndex;
            }
            // }
            else if (c == ']')
            {
                // Grab the last label off the stack, and use it
                auto labelString = labelStack[$-1].to!string();
                labelStack.length--;

                mov(EAX, _(Byte, EBX));
                cmp(EAX, 0);
                jne("l" ~ labelString);
                label("r" ~ labelString);
            }
        }
    }

    return block;
}

BasicBlock compileOptimizedBF(string input)
{
    BasicBlock block;

    enum Opcode
    {
        Add,
        Subtract,
        Forward,
        Backward,
        Output,
        Input,
        LeftBracket,
        RightBracket
    }

    struct Instruction
    {
        Opcode opcode;
        int value;
    }

    uint labelIndex = 0;
    uint[] labelStack;
    Instruction[] ir;

    void addFoldableInstruction(Opcode opcode)
    {
        if (ir.length && ir[$-1].opcode == opcode)
            ir[$-1].value++;
        else
            ir ~= Instruction(opcode, 1);
    }

    // Build up IR
    foreach (c; input)
    {
        // *ptr++
        if (c == '+')
            addFoldableInstruction(Opcode.Add);
        // *ptr--
        else if (c == '-')
            addFoldableInstruction(Opcode.Subtract);
        // ptr++
        else if (c == '>')
            addFoldableInstruction(Opcode.Forward);
        // ptr--
        else if (c == '<')
            addFoldableInstruction(Opcode.Backward);
        // putchar(*ptr)
        else if (c == '.')
            ir ~= Instruction(Opcode.Output, 0);
        // *ptr = getchar()
        else if (c == ',')
            ir ~= Instruction(Opcode.Input, 0);
        // while (*ptr) {
        else if (c == '[')
        {
            ir ~= Instruction(Opcode.LeftBracket, labelIndex);

            // Push back the current index to the label stack
            labelStack ~= labelIndex;
            ++labelIndex;
        }
        // }
        else if (c == ']')
        {
            // Grab the last label off the stack, and use it
            ir ~= Instruction(Opcode.RightBracket, labelStack[$-1]);
            labelStack.length--;
        }
    }

    // Dump out IR
    ir.each!writeln();

    // Build machine code
    with (block) with (Register) with (OperandType)
    {
        // Load in array at EBX, as the D ABI guarantees it won't be 
        // trampled by function calls
        mov(EBX, _(EBP, 8));

        foreach (instruction; ir)
        {
            if (instruction.opcode == Opcode.Add)
            {
                add(_(Byte, EBX), cast(byte)instruction.value);
            }
            else if (instruction.opcode == Opcode.Subtract)
            {
                sub(_(Byte, EBX), cast(byte)instruction.value);
            }
            else if (instruction.opcode == Opcode.Forward)
            {
                // Avoid emitting a large immediate where possible
                if (instruction.value == 1)
                    inc(EBX);
                else if (instruction.value.fitsIn!byte)
                    add(EBX, cast(byte)instruction.value);
                else
                    add(EBX, instruction.value);
            }
            else if (instruction.opcode == Opcode.Backward)
            {
                // Avoid emitting a large immediate where possible
                if (instruction.value == 1)
                    dec(EBX);
                else if (instruction.value.fitsIn!byte)
                    sub(EBX, cast(byte)instruction.value);
                else
                    sub(EBX, instruction.value);
            }
            else if (instruction.opcode == Opcode.Output)
            {
                mov(EAX, _(Byte, EBX));
                call(&putchar);
            }
            else if (instruction.opcode == Opcode.Input)
            {
                call(&getchar);
                mov(_(Byte, EBX), EAX);
            }
            else if (instruction.opcode == Opcode.LeftBracket)
            {
                // Generate label
                auto labelString = instruction.value.to!string();

                mov(EAX, _(Byte, EBX));
                cmp(EAX, 0);
                je("r" ~ labelString);
                label("l" ~ labelString);
            }
            else if (instruction.opcode == Opcode.RightBracket)
            {
                // Grab the last label off the stack, and use it
                auto labelString = instruction.value.to!string();

                mov(EAX, _(Byte, EBX));
                cmp(EAX, 0);
                jne("l" ~ labelString);
                label("r" ~ labelString);
            }
        }
    }

    return block;
}

void main(string[] args)
{
    if (args.length < 2)
    {
        writeln("jitbrained filepath");
        return;
    }

    auto testString = args[1].readText();

    BasicBlock preludeBlock, endBlock;

    with (preludeBlock) with (Register)
    {
        push(EBP);
        mov(EBP, ESP);
    }

    with (endBlock) with (Register)
    {
        pop(EBP);
        ret;
    }

    auto assembly = Assembly(preludeBlock, testString.compileOptimizedBF(), endBlock);
    assembly.finalize();
    writeln("Byte count: ", assembly.buffer.length);
    writeln("-------");

    ubyte[30_000] state;
    assembly(state.ptr);
}